///|
priv struct H3PeerSocket {
  socket : @transport_native.UdpServerSocket
  inbox : @aqueue.Queue[@transport.Datagram]
  remove_route : () -> Unit
  mut closed : Bool
}

///|
impl @transport.DatagramSocket for H3PeerSocket with fn send(
  self,
  endpoint,
  bytes,
) {
  if self.closed {
    return Err(Closed)
  }
  self.socket.send(endpoint, bytes)
}

///|
impl @transport.DatagramSocket for H3PeerSocket with fn receive(self, max_bytes) {
  if self.closed {
    return Err(Closed)
  }
  let packet = self.inbox.get() catch {
    error => if self.closed { return Err(Closed) } else { raise error }
  }
  if packet.payload().length() > max_bytes {
    return Err(InvalidDatagramSize)
  }
  Ok(packet)
}

///|
impl @transport.DatagramSocket for H3PeerSocket with fn close(self) {
  if !self.closed {
    self.closed = true
    (self.remove_route)()
    self.inbox.close(clear=true)
  }
}

///|
priv struct H3Admissions {
  pending : @aqueue.Queue[@server_api.AcceptedConnection]
  mut closed : Bool
}

///|
impl @server_api.Listener for H3Admissions with fn accept(self) {
  if self.closed {
    return Ok(None)
  }
  let result = self.pending.get() catch {
    err => if self.closed { return Ok(None) } else { raise err }
  }
  Ok(Some(result))
}

///|
impl @server_api.Listener for H3Admissions with fn close(self) {
  if !self.closed {
    self.closed = true
    let queued = self.pending.try_get() catch { _ => None }
    if queued is Some(peer) {
      (peer.close)()
    }
    self.pending.close()
  }
}

///|
/// One UDP socket routes server-issued connection IDs. Initial retransmissions
/// use their original destination ID and source endpoint until the peer closes.
pub struct NativeHttp3Listener {
  priv socket : @transport_native.UdpServerSocket
  priv admissions : H3Admissions
  priv routes : Map[Bytes, H3PeerSocket]
  priv initials : Map[(@types.Endpoint, Bytes), H3PeerSocket]
  priv run_peer : async (
    H3PeerSocket,
    @types.Endpoint,
    @quic.ConnectionId,
    @quic.ConnectionId,
    @quic.ConnectionId,
  ) -> Unit
  priv inbox_capacity : Int
  priv datagram_size : Int
  priv mut serving : Bool
}

///|
fn[T, E : Error] h3_listener_value(result : Result[T, E]) -> T raise E {
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
pub async fn[P : @transport.NetworkPolicy] NativeHttp3Listener::bind(
  endpoint : @types.Endpoint,
  policy : P,
  options : @transport.TlsOptions,
  handler : async (@types.Endpoint, @service.H3ConnectionIo) -> Unit,
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params? : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  pending_datagrams_per_peer? : Int = 16,
  handshake_timeout_ms? : Int = 10000,
  shutdown_timeout_ms? : Int = 5000,
) -> Result[NativeHttp3Listener, @server_api.ServerError] {
  if pending_datagrams_per_peer <= 0 ||
    handshake_timeout_ms <= 0 ||
    shutdown_timeout_ms <= 0 {
    return Err(
      InvalidConfig("HTTP/3 queue capacity and timeouts must be positive"),
    )
  }
  if options.validate_server() is Err(_) ||
    options.alpn != ["h3"] ||
    options.min_version != Tls13 ||
    options.server_certificate is None {
    return Err(
      InvalidConfig("HTTP/3 requires server credentials, TLS 1.3 and h3 ALPN"),
    )
  }
  if qpack_limits.validate_for(limits) is Err(_) ||
    transport_params.validate() is Err(_) {
    return Err(InvalidConfig("invalid HTTP/3 limits or transport parameters"))
  }
  let socket = match
    @transport_native.UdpServerSocket::bind(
      endpoint,
      policy,
      max_datagram_size=limits.max_datagram_bytes,
    ) {
    Ok(value) => value
    Err(Policy(error)) => return Err(Policy(error))
    Err(error) => return Err(AcceptFailed("\{Repr(error)}"))
  }
  let clock = @transport_native.NativeClock::new()
  let run_peer = async fn(peer, source, original, local_id, remote_id) {
    let packets = h3_listener_value(
      @quic.QuicDatagramDriver::new(
        Server,
        source,
        original,
        local_id,
        remote_id,
        now_ms=clock.monotonic_millis(),
        transport_params~,
        authorize=fn(endpoint, operation) {
          policy.authorize(endpoint, operation)
        },
      ),
    )
    let provider = @tls_native.NativeQuicTlsProvider::new(server=true)
    defer provider.close()
    let tls = h3_listener_value(@quic.QuicTlsDriver::new(packets, provider))
    @service.with_http3_connection(
      tls,
      peer,
      clock,
      options,
      async fn(io) { handler(source, io) },
      limits~,
      qpack_limits~,
      handshake_timeout_ms~,
      shutdown_timeout_ms~,
    ) catch {
      @quic.QuicError::ConnectionClosed(0L | 0x100L, _) if packets.state() ==
        Draining => ()
      err => raise err
    }
  }
  Ok({
    socket,
    admissions: { pending: Queue(kind=Blocking(1)), closed: false, },
    routes: Map([]),
    initials: Map([]),
    run_peer,
    inbox_capacity: pending_datagrams_per_peer,
    datagram_size: limits.max_datagram_bytes,
    serving: false,
  })
}

///|
fn NativeHttp3Listener::route(
  self : NativeHttp3Listener,
  packet : @transport.Datagram,
) -> Unit raise {
  let bytes = packet.payload()
  if bytes.is_empty() {
    return
  }
  let source = packet.endpoint()
  let peer = if (bytes[0].to_int() & 0x80) == 0 {
    // Short headers omit the destination CID length. All locally issued IDs
    // for this listener are sixteen bytes.
    if bytes.length() < 17 || (bytes[0].to_int() & 0x40) == 0 {
      return
    }
    guard self.routes.get(bytes[1:17].to_owned()) is Some(peer) else { return }
    peer
  } else {
    guard @quic.quic_long_header_fields(bytes)
      is Ok((1, destination, remote, kind, _, _)) else {
      return
    }
    let id = destination.bytes()
    if self.routes.get(id) is Some(peer) {
      peer
    } else {
      if kind != 0 || id.length() < 8 || bytes.length() < 1200 {
        return
      }
      let key = (source, id)
      match self.initials.get(key) {
        Some(peer) => peer
        None => {
          if self.admissions.closed {
            return
          }
          let mut issued : Bytes? = None
          let peer = {
            socket: self.socket,
            inbox: Queue(kind=Blocking(self.inbox_capacity)),
            closed: false,
            remove_route: fn() {
              if issued is Some(cid) {
                self.routes.remove(cid)
              }
              self.initials.remove(key)
            },
          }
          let accepted = @server_api.AcceptedConnection::new(
            async fn() {
              try {
                // Allocate the CID and TLS state only after the supervisor grants a slot.
                let cid = h3_listener_value(
                  @quic.ConnectionId::random(@tls_native.NativeEntropy::new()),
                )
                let local_id = cid.bytes()
                if self.routes.contains(local_id) ||
                  self.initials.contains((source, local_id)) {
                  raise @quic.QuicError::InvalidPacket(
                    "server connection ID collision",
                  )
                }
                issued = Some(local_id)
                self.routes[local_id] = peer
                (self.run_peer)(peer, source, destination, cid, remote)
                Ok(())
              } catch {
                err => Err(err)
              }
            },
            fn() { @transport.DatagramSocket::close(peer) },
          )
          if !self.admissions.pending.try_put(accepted) {
            return
          }
          self.initials[key] = peer
          peer
        }
      }
    }
  }
  // One stalled consumer may lose datagrams. The shared receiver remains
  // available to other peers, and QUIC recovery retransmits lost stream data.
  ignore(peer.inbox.try_put(packet))
}

///|
/// Stop new admissions. The shared UDP socket keeps serving accepted peers
/// while the supervisor drains them.
pub fn NativeHttp3Listener::close(self : NativeHttp3Listener) -> Unit {
  @server_api.Listener::close(self.admissions)
  if !self.serving {
    self.socket.close()
  }
}

///|
/// Serve once. The supervisor owns connection limits, error accounting and
/// the graceful shutdown deadline. Cancelling the scope releases all routes.
pub async fn NativeHttp3Listener::serve(
  self : NativeHttp3Listener,
  supervisor : @server_api.ServerSupervisor,
) -> Result[Unit, @server_api.ServerError] {
  if self.serving {
    return Err(AlreadyRunning)
  }
  if self.admissions.closed {
    return Err(Closed)
  }
  self.serving = true
  defer {
    self.serving = false
    self.close()
  }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(
      async fn() {
        while true {
          match self.socket.receive(self.datagram_size) {
            Ok(packet) => self.route(packet)
            Err(Policy(_) | InvalidDatagramSize) => continue
            Err(error) =>
              if @async.is_being_cancelled() {
                return
              } else {
                raise error
              }
          }
        }
      },
      no_wait=true,
    )
    supervisor.serve(self.admissions)
  }) catch {
    error => Err(AcceptFailed(error.to_string()))
  }
}

///|
/// Serve the same streaming request handler used by the HTTP/1 and HTTP/2
/// listeners. Incoming request windows are capped by the body buffer limit.
pub async fn[P : @transport.NetworkPolicy, B : @body.Body] NativeHttp3Listener::bind_http(
  endpoint : @types.Endpoint,
  policy : P,
  options : @transport.TlsOptions,
  handler : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params? : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  pending_datagrams_per_peer? : Int = 16,
  handshake_timeout_ms? : Int = 10000,
  shutdown_timeout_ms? : Int = 5000,
) -> Result[NativeHttp3Listener, @server_api.ServerError] {
  let budget = limits.max_buffer_bytes.to_int64()
  NativeHttp3Listener::bind(
    endpoint,
    policy,
    options,
    (_, io) => @service.serve_http3_connection(io, handler),
    limits~,
    qpack_limits~,
    transport_params={
      ..transport_params,
      initial_max_stream_data_bidi_remote: transport_params.initial_max_stream_data_bidi_remote.min(
        budget,
      ),
    },
    pending_datagrams_per_peer~,
    handshake_timeout_ms~,
    shutdown_timeout_ms~,
  )
}
