///|
/// Scoped I/O for one HTTP/3 connection on a dedicated datagram socket.
/// One consumer reads event batches. The reader and recovery timer keep
/// running while application code handles a batch.
pub struct Http3ConnectionIo {
  session : @http3.Http3Session
  priv mut timer_polls : Int64
  priv mut deadline_wakeups : Int64
  priv server_shutdown : ServerShutdown?
  priv authenticated_origin : @types.Endpoint?
  priv mut failure : Error?
  priv limits : @types.Limits
  priv write_changed : @cond_var.Cond
  priv events : @aqueue.Queue[Array[@http3.Http3SessionAction]]
  priv cancel_request : (Int64, @http3.H3ErrorCode) -> Unit
  priv rotate_cid : async () -> Unit
  priv flush_writes : async () -> Unit
}

///|
/// Cumulative transport polls and polls caused by an expired clock deadline.
/// Input, application writes and returned flow-control credit can also cause polls.
pub fn Http3ConnectionIo::poll_counts(
  self : Http3ConnectionIo,
) -> (Int64, Int64) {
  (self.timer_polls, self.deadline_wakeups)
}

///|
/// Hand queued application writes to QUIC immediately. A blocked prefix
/// remains queued for the background reader and timer.
pub async fn Http3ConnectionIo::flush(self : Http3ConnectionIo) -> Unit {
  (self.flush_writes)()
}

///|
/// Request a change of this endpoint's QUIC connection ID. The peer can
/// finish in-flight traffic while retirement and recovery run in the background.
pub async fn Http3ConnectionIo::rotate_local_connection_id(
  self : Http3ConnectionIo,
) -> Unit {
  (self.rotate_cid)()
}

///|
/// Flush application writes and wait for the next batch of peer events.
pub async fn Http3ConnectionIo::next_events(
  self : Http3ConnectionIo,
) -> Array[@http3.Http3SessionAction] {
  self.flush()
  self.events.get()
}

///|
/// Run an authenticated HTTP/3 peer on a dedicated socket. The scope owns
/// socket closure, the receiver and the recovery timer. The caller owns the
/// TLS provider. The callback starts after the handshake and critical streams
/// are ready. Returning ends the connection; finish outstanding exchanges
/// inside the callback. Normal shutdown drains queued writes and their QUIC
/// acknowledgments within shutdown_timeout_ms. Timeouts are in milliseconds.
pub async fn[
  P : @transport.QuicTlsProvider,
  S : @transport.DatagramSocket,
  K : @transport.Clock,
  X,
] with_http3_connection(
  tls : @quic.QuicTlsDriver[P],
  socket : S,
  clock : K,
  options : @transport.TlsOptions,
  run : async (Http3ConnectionIo) -> X,
  server_shutdown~ : ServerShutdown? = None,
  limits~ : @types.Limits = @types.Limits::defaults(),
  qpack_limits~ : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  handshake_timeout_ms~ : Int32? = Some(10000),
  shutdown_timeout_ms~ : Int32 = 5000,
) -> X {
  defer socket.close()
  if handshake_timeout_ms is Some(ms) && ms <= 0 {
    raise ServiceConfigError::InvalidTimeout("HTTP/3 handshake", ms)
  }
  if shutdown_timeout_ms <= 0 {
    raise ServiceConfigError::InvalidTimeout(
      "HTTP/3 shutdown", shutdown_timeout_ms,
    )
  }
  let timer_changed = @cond_var.Cond()
  let mut needs_poll = false
  fn wake_driver() {
    if !needs_poll {
      needs_poll = true
      timer_changed.signal()
    }
  }
  let session = @http3.Http3Session::new(
    tls,
    limits~,
    qpack_limits~,
    on_pending=wake_driver,
  ).unwrap_or_error()
  let events : @aqueue.Queue[Array[@http3.Http3SessionAction]] = Queue(
    kind=Blocking(1),
  )
  let write_changed = @cond_var.Cond()
  let ready : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let drained : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let mut draining = false
  let mut closing = false
  let mut peer_close : @quic.QuicError? = None
  let mut connected = false
  let packets = tls.datagram_driver()
  let flush_needed = @cond_var.Cond()
  let mut requested = 0L
  let mut completed = 0L
  let mut write_failure : Error? = None
  let send_lock = @async.Mutex()
  fn request_flush() -> Int64 {
    requested += 1L
    flush_needed.signal()
    requested
  }
  let mut reset_error : @http3.Http3Error? = None
  fn cancel_request(id : Int64, code : @http3.H3ErrorCode) -> Unit {
    defer ignore(request_flush())
    match session.cancel(id, code~) {
      Ok(_) | Err(Http3StreamError(_, H3RequestCancelled, _)) => ()
      Err(error) => reset_error = Some(error)
    }
  }
  // A failing scope still owns the socket until its defers finish. Give
  // the peer a bounded close notification before dropping its UDP route.
  defer {
    events.close()
    if session.close(clock.monotonic_millis(), code=H3InternalError)
      is Ok(Some(packet)) {
      @async.protect_from_cancel(async fn() {
        @async.with_timeout(shutdown_timeout_ms, async fn() {
          ignore(packets.send_action(socket, packet))
        }) catch {
          _ => ()
        }
      })
    }
  }
  async fn dispatch_events(
    prepare : () -> Array[@quic.QuicDriverAction] raise,
    from_timer : Bool,
  ) -> Unit {
    let batch = []
    let terminal = {
      send_lock.acquire()
      defer send_lock.release()
      if closing || peer_close is Some(_) {
        return
      }
      if reset_error is Some(error) {
        raise error
      }
      // QUIC changes its state when producing actions. Advance the HTTP/3
      // session with those actions before another task can observe that state.
      let actions = prepare()
      let advanced = session.advance(actions, clock.monotonic_millis())
      if !from_timer {
        wake_driver()
      }
      // Sending a datagram yields. Only a batch that observed a terminal
      // session can report its end or close the application event queue.
      let terminal = session.ended()
      for event in advanced {
        match event {
          Transport(SendDatagram(_, _) as packet) =>
            packets.send_action(socket, packet).unwrap_or_error()
          Failed(error) => raise error
          Transport(ConnectionClosed(code, reason)) => {
            let error = @quic.QuicError::ConnectionClosed(code, reason)
            if !connected || !@http3.peer_closed_normally(packets.connection()) {
              raise error
            }
            // Preserve previously delivered batches, including a final response.
            // A further read observes the close after buffered events are consumed.
            peer_close = Some(error)
          }
          Transport(StreamReset(_, _) | SendStopped(_, _)) => batch.push(event)
          Transport(_) => ()
          other => batch.push(other)
        }
      }
      if !advanced.is_empty() || !actions.is_empty() {
        write_changed.broadcast()
      }
      terminal
    }
    if terminal &&
      peer_close is None &&
      packets.connection().peer_close() is None {
      raise @quic.QuicError::ConnectionClosed(0L, "HTTP/3 connection ended")
    }
    if !connected && packets.state() == Established {
      connected = true
      ignore(ready.try_put(()))
    }
    if draining {
      if !session.writes_pending() || peer_close is Some(_) {
        ignore(drained.try_put(()))
      }
    } else if !batch.is_empty() {
      events.put(batch) catch {
        err => if !draining { raise err }
      }
    }
    if terminal && peer_close is Some(error) {
      events.close(error~)
    }
  }
  async fn dispatch(
    prepare : () -> Array[@quic.QuicDriverAction] raise,
  ) -> Unit {
    dispatch_events(prepare, false)
  }
  let authenticated_origin = if packets.role() == Client &&
    options.verify_peer &&
    options.server_name is Some(host) {
    match @types.Endpoint::new("https", host, packets.endpoint().port) {
      Ok(origin) => Some(origin)
      Err(_) => None
    }
  } else {
    None
  }
  let io = {
    authenticated_origin,
    timer_polls: 0L,
    deadline_wakeups: 0L,
    failure: None,
    server_shutdown,
    cancel_request,
    session,
    limits,
    write_changed,
    events,
    rotate_cid: async fn() {
      dispatch(() => {
        packets
        .rotate_local_connection_id(clock.monotonic_millis())
        .unwrap_or_error()
      })
    },
    flush_writes: async fn() {
      let ticket = request_flush()
      while completed < ticket &&
            write_failure is None &&
            !closing &&
            peer_close is None {
        write_changed.wait()
      }
      if write_failure is Some(error) {
        raise error
      }
    },
  }
  @async_support.with_group_result(async fn(group) {
    // The request tasks may live in a pool outside this connection scope.
    // Preserve the driver error before structured cancellation unwinds it.
    fn spawn_driver(task : async () -> Unit) -> Unit {
      group.spawn_bg(
        async fn() {
          task() catch {
            // During group teardown, another driver can already observe the
            // closed QUIC state. A second raised error would replace the
            // original socket, TLS, or application error in the task group.
            _ if io.failure is Some(_) || @async.is_being_cancelled() => ()
            error => {
              io.failure = Some(error)
              write_failure = Some(error)
              write_changed.broadcast()
              raise error
            }
          }
        },
        no_wait=true,
      )
    }
    // Cancellation of a single request can stop waiting for its ticket while
    // the connection owner finishes sending the datagrams already emitted by QUIC.
    spawn_driver(async fn() {
      while true {
        while completed == requested {
          flush_needed.wait()
        }
        let ticket = requested
        dispatch(() => [])
        completed = ticket
        write_changed.broadcast()
      }
    })
    spawn_driver(async fn() {
      dispatch(() => {
        tls.start(options, clock.monotonic_millis()).unwrap_or_error()
      })
      while peer_close is None {
        let packet = socket.receive(limits.max_datagram_bytes).unwrap_or_error()
        // MAX_STREAMS can admit a writer without producing an application event.
        dispatch(() => {
          write_changed.broadcast()
          tls
          .on_datagram(
            packet.endpoint(),
            packet.payload(),
            clock.monotonic_millis(),
          )
          .unwrap_or_error()
        })
      }
    })
    spawn_driver(async fn() {
      let mut last_poll_ms = None
      while peer_close is None && !closing {
        if !needs_poll {
          match packets.next_poll_deadline(last_poll_ms?) {
            Some(deadline) => {
              let wait_ms = deadline - clock.monotonic_millis()
              if wait_ms > 0L {
                let delay = wait_ms.min(0x7fffffffL).to_int()
                ignore(
                  @async.with_timeout_opt(delay, async fn() {
                    if !needs_poll {
                      timer_changed.wait()
                    }
                  }),
                )
                // Int-sized timers can expire before a distant Int64 deadline.
                if !needs_poll && clock.monotonic_millis() < deadline {
                  continue
                }
              }
            }
            None => {
              timer_changed.wait()
              continue
            }
          }
        }
        if !needs_poll {
          io.deadline_wakeups += 1L
        }
        needs_poll = false
        dispatch_events(
          () => {
            let now = clock.monotonic_millis()
            io.timer_polls += 1L
            last_poll_ms = Some(now)
            tls.poll(now).unwrap_or_error()
          },
          true,
        )
      }
    })
    match handshake_timeout_ms {
      Some(ms) => @async.with_timeout(ms, () => ready.get())
      None => ready.get()
    }
    let result = run(io)
    draining = true
    events.close(clear=true)
    @async.with_timeout(shutdown_timeout_ms, async fn() {
      dispatch(() => [])
      if session.writes_pending() && peer_close is None {
        drained.get()
      }
      if session.writes_pending() && peer_close is Some(error) {
        raise error
      }
      closing = true
      send_lock.acquire()
      defer send_lock.release()
      if session.close(clock.monotonic_millis()).unwrap_or_error()
        is Some(packet) {
        packets.send_action(socket, packet).unwrap_or_error()
      }
    })
    result
  })
}
