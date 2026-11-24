///|
/// Scoped I/O for one HTTP/3 connection on a dedicated datagram socket.
/// One consumer reads event batches. The reader and recovery timer keep
/// running while application code handles a batch.
pub struct Http3ConnectionIo {
  session : @http3.Http3Session
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
  handshake_timeout_ms~ : Int32 = 10000,
  shutdown_timeout_ms~ : Int32 = 5000,
) -> X {
  defer socket.close()
  if handshake_timeout_ms <= 0 {
    raise ServiceConfigError::InvalidTimeout(
      "HTTP/3 handshake", handshake_timeout_ms,
    )
  }
  if shutdown_timeout_ms <= 0 {
    raise ServiceConfigError::InvalidTimeout(
      "HTTP/3 shutdown", shutdown_timeout_ms,
    )
  }
  let session = @http3.Http3Session::new(tls, limits~, qpack_limits~).unwrap_or_error()
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
  let mut reset_error : @http3.Http3Error? = None
  fn cancel_request(id : Int64, code : @http3.H3ErrorCode) -> Unit {
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
  async fn dispatch(actions : Array[@quic.QuicDriverAction]) -> Unit {
    if closing || peer_close is Some(_) {
      return
    }
    if reset_error is Some(error) {
      raise error
    }
    let batch = []
    let advanced = session.advance(actions, clock.monotonic_millis())
    // Sending a datagram yields. Only a batch that observed a terminal
    // session can report its end or close the application event queue.
    let terminal = session.ended()
    if !advanced.is_empty() || !actions.is_empty() {
      write_changed.broadcast()
    }
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
    failure: None,
    server_shutdown,
    cancel_request,
    session,
    limits,
    write_changed,
    events,
    rotate_cid: async fn() {
      dispatch(
        packets
        .rotate_local_connection_id(clock.monotonic_millis())
        .unwrap_or_error(),
      )
    },
    flush_writes: async fn() { dispatch([]) },
  }
  @async_support.with_group_result(async fn(group) {
    // The request tasks may live in a pool outside this connection scope.
    // Preserve the driver error before structured cancellation unwinds it.
    fn spawn_driver(task : async () -> Unit) -> Unit {
      group.spawn_bg(
        async fn() {
          task() catch {
            error if io.failure is None && !@async.is_being_cancelled() => {
              io.failure = Some(error)
              raise error
            }
            error => raise error
          }
        },
        no_wait=true,
      )
    }
    spawn_driver(async fn() {
      dispatch(tls.start(options, clock.monotonic_millis()).unwrap_or_error())
      while peer_close is None {
        let packet = socket.receive(limits.max_datagram_bytes).unwrap_or_error()
        // MAX_STREAMS can admit a writer without producing an application event.
        write_changed.broadcast()
        dispatch(
          tls
          .on_datagram(
            packet.endpoint(),
            packet.payload(),
            clock.monotonic_millis(),
          )
          .unwrap_or_error(),
        )
      }
    })
    spawn_driver(async fn() {
      while true {
        @async.sleep(25)
        if peer_close is Some(_) || closing {
          return
        }
        dispatch(tls.poll(clock.monotonic_millis()).unwrap_or_error())
      }
    })
    @async.with_timeout(handshake_timeout_ms, async fn() { ready.get() })
    let result = run(io)
    draining = true
    events.close(clear=true)
    @async.with_timeout(shutdown_timeout_ms, async fn() {
      dispatch([])
      if session.writes_pending() && peer_close is None {
        drained.get()
      }
      if session.writes_pending() && peer_close is Some(error) {
        raise error
      }
      closing = true
      if session.close(clock.monotonic_millis()).unwrap_or_error()
        is Some(packet) {
        packets.send_action(socket, packet).unwrap_or_error()
      }
    })
    result
  })
}
