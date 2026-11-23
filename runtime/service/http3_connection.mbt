///|
/// Scoped I/O for one HTTP/3 connection on a dedicated datagram socket.
/// One consumer reads event batches. The reader and recovery timer keep
/// running while application code handles a batch.
pub struct H3ConnectionIo {
  session : @http3.Http3Session
  priv authenticated_origin : @types.Endpoint?
  priv limits : @types.Limits
  priv write_changed : @cond_var.Cond
  priv events : @aqueue.Queue[Array[@http3.Http3SessionAction]]
  priv cancel_request : (Int64) -> Unit
  priv flush_writes : async () -> Unit
}

///|
/// Hand queued application writes to QUIC immediately. A blocked prefix
/// remains queued for the background reader and timer.
pub async fn H3ConnectionIo::flush(self : H3ConnectionIo) -> Unit {
  (self.flush_writes)()
}

///|
/// Flush application writes and wait for the next batch of peer events.
pub async fn H3ConnectionIo::next_events(
  self : H3ConnectionIo,
) -> Array[@http3.Http3SessionAction] {
  self.flush()
  self.events.get()
}

///|
fn[T, E : Error] h3_io_value(result : Result[T, E]) -> T raise E {
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
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
  run : async (H3ConnectionIo) -> X,
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  handshake_timeout_ms? : Int = 10000,
  shutdown_timeout_ms? : Int = 5000,
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
  let session = h3_io_value(
    @http3.Http3Session::new(tls, limits~, qpack_limits~),
  )
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
  let pending_resets : Set[Int64] = Set([])
  let mut reset_error : @http3.Http3Error? = None
  fn cancel_request(id : Int64) -> Unit {
    match session.cancel(id) {
      Ok(_) | Err(Http3StreamError(_, H3RequestCancelled, _)) =>
        pending_resets.remove(id)
      Err(Http3WriteBlocked) =>
        if !pending_resets.contains(id) &&
          pending_resets.length() >= limits.max_streams {
          reset_error = Some(
            Http3LimitExceeded(
              "HTTP/3 pending cancellations",
              limits.max_streams,
            ),
          )
        } else {
          pending_resets.add(id)
        }
      Err(error) => reset_error = Some(error)
    }
  }
  // Invalidate escaped session handles on cancellation or application errors.
  defer {
    ignore(session.close(clock.monotonic_millis()))
    events.close()
  }
  async fn dispatch(actions : Array[@quic.QuicDriverAction]) -> Unit {
    if closing || peer_close is Some(_) {
      return
    }
    // Synchronous body cancellation also wakes blocked producers. A full
    // QPACK output queue delays the wire reset until the next transport turn.
    if !pending_resets.is_empty() {
      for id in pending_resets.to_array() {
        cancel_request(id)
      }
    }
    if reset_error is Some(error) {
      raise error
    }
    let batch = []
    let advanced = session.advance(actions, clock.monotonic_millis())
    if !advanced.is_empty() || !actions.is_empty() {
      write_changed.broadcast()
    }
    for event in advanced {
      match event {
        Transport(SendDatagram(_, _) as packet) =>
          h3_io_value(packets.send_action(socket, packet))
        Failed(error) => raise error
        Transport(ConnectionClosed(code, reason)) => {
          let error = @quic.QuicError::ConnectionClosed(code, reason)
          if !connected ||
            packets.state() != Draining ||
            (code != 0L && code != 0x100L) {
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
    if session.ended() && peer_close is None {
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
    if peer_close is Some(error) {
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
    cancel_request,
    session,
    limits,
    write_changed,
    events,
    flush_writes: async fn() { dispatch([]) },
  }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(
      async fn() {
        dispatch(h3_io_value(tls.start(options, clock.monotonic_millis())))
        while peer_close is None {
          let packet = h3_io_value(socket.receive(limits.max_datagram_bytes))
          // MAX_STREAMS can admit a writer without producing an application event.
          write_changed.broadcast()
          dispatch(
            h3_io_value(
              tls.on_datagram(
                packet.endpoint(),
                packet.payload(),
                clock.monotonic_millis(),
              ),
            ),
          )
        }
      },
      no_wait=true,
    )
    group.spawn_bg(
      async fn() {
        while true {
          @async.sleep(25)
          if peer_close is Some(_) || closing {
            return
          }
          dispatch(h3_io_value(tls.poll(clock.monotonic_millis())))
        }
      },
      no_wait=true,
    )
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
      if h3_io_value(session.close(clock.monotonic_millis())) is Some(packet) {
        h3_io_value(packets.send_action(socket, packet))
      }
    })
    result
  })
}
