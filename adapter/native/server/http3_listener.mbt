///|
priv struct H3PeerSocket {
  socket : @transport_native.UdpServerSocket
  inbox : @aqueue.Queue[@transport.Datagram]
  routes : Map[Bytes, H3PeerSocket]
  owned : Set[Bytes]
  initials : Map[@types.Endpoint, Map[Bytes, H3PeerSocket]]
  initial_key : (@types.Endpoint, Bytes)
  mut packets : @quic.QuicDatagramDriver?
  mut closed : Bool
}

///|
fn H3PeerSocket::reserve_route(
  self : H3PeerSocket,
  id : @quic.ConnectionId,
) -> Bool {
  let bytes = id.bytes()
  if self.closed ||
    self.routes.contains(bytes) ||
    (
      self.initials.get(self.initial_key.0) is Some(peers) &&
      peers.contains(bytes)
    ) {
    return false
  }
  self.owned.add(bytes)
  self.routes[bytes] = self
  true
}

///|
fn H3PeerSocket::release_route(
  self : H3PeerSocket,
  id : @quic.ConnectionId,
) -> Unit {
  let bytes = id.bytes()
  if self.owned.contains(bytes) {
    self.owned.remove(bytes)
    self.routes.remove(bytes)
  }
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
  let packet = self.inbox.get() catch {
    @aqueue.QueueAlreadyClosed => return Err(Closed)
    error => raise error
  }
  if packet.payload().length() > max_bytes {
    return Err(InvalidDatagramSize)
  }
  Ok(packet)
}

///|
impl @transport.DatagramSocket for H3PeerSocket with fn close(self) {
  self.finish()
}

///|
fn H3PeerSocket::receive_reset(
  self : H3PeerSocket,
  packet : @transport.Datagram,
) -> Bool {
  guard self.packets is Some(driver) &&
    driver.receive_stateless_reset(packet.endpoint(), packet.payload())
    is Some(error) else {
    return false
  }
  self.finish(error~)
  true
}

///|
fn H3PeerSocket::finish(self : H3PeerSocket, error? : Error) -> Unit {
  if !self.closed {
    self.closed = true
    for id in self.owned {
      self.routes.remove(id)
    }
    self.owned.clear()
    if self.initials.get(self.initial_key.0) is Some(peers) {
      peers.remove(self.initial_key.1)
      if peers.is_empty() {
        self.initials.remove(self.initial_key.0)
      }
    }
    self.inbox.close(clear=true, error?)
  }
}

///|
priv struct H3Admissions {
  pending : @aqueue.Queue[@server_api.AcceptedConnection]
  shutdown : @service.ServerShutdown
}

///|
impl @server_api.Listener for H3Admissions with fn accept(self) {
  if self.shutdown.has_started() {
    return Ok(None)
  }
  let result = self.pending.get() catch {
    err => if self.shutdown.has_started() { return Ok(None) } else { raise err }
  }
  Ok(Some(result))
}

///|
impl @server_api.Listener for H3Admissions with fn close(self) {
  if !self.shutdown.has_started() {
    self.shutdown.begin()
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
  priv initials : Map[@types.Endpoint, Map[Bytes, H3PeerSocket]]
  priv run_peer : async (
    H3PeerSocket,
    @types.Endpoint,
    @quic.ConnectionId,
    @quic.ConnectionId,
    @quic.ConnectionId,
  ) -> Unit
  priv inbox_capacity : Int32
  priv datagram_size : Int32
  priv mut serving : Bool
}

///|
pub async fn[P : @transport.NetworkPolicy] NativeHttp3Listener::bind(
  endpoint : @types.Endpoint,
  policy : P,
  options : @transport.TlsOptions,
  handler : async (@types.Endpoint, @service.Http3ConnectionIo) -> Unit,
  limits~ : @types.Limits = @types.Limits::defaults(),
  qpack_limits~ : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params~ : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  pending_datagrams_per_peer~ : Int32 = 16,
  handshake_timeout_ms~ : Int32 = 10000,
  shutdown_timeout_ms~ : Int32 = 5000,
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
    limits.max_datagram_bytes < 1200 ||
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
  let shutdown = @service.ServerShutdown::new()
  let run_peer = async fn(
    peer : H3PeerSocket,
    source,
    original,
    local_id,
    remote_id,
  ) {
    let packets = @quic.QuicDatagramDriver::new(
      Server,
      source,
      original,
      local_id,
      remote_id,
      now_ms=clock.monotonic_millis(),
      limits={
        ..@quic.QuicLimits::defaults(),
        max_datagram_size: limits.max_datagram_bytes,
      },
      transport_params~,
      authorize=fn(endpoint, operation) {
        policy.authorize(endpoint, operation)
      },
    ).unwrap_or_error()
    peer.packets = Some(packets)
    defer {
      peer.packets = None
    }
    packets
    .enable_connection_id_issuance(
      @tls_native.NativeEntropy::new(),
      reserve=id => peer.reserve_route(id),
      release=id => peer.release_route(id),
    )
    .unwrap_or_error()
    let provider = @tls_native.NativeQuicTlsProvider::new(server=true)
    defer provider.close()
    let tls = @quic.QuicTlsDriver::new(packets, provider).unwrap_or_error()
    let mut authenticated = false
    @service.with_http3_connection(
      tls,
      peer,
      clock,
      options,
      async fn(io) {
        authenticated = true
        handler(source, io)
      },
      server_shutdown=Some(shutdown),
      limits~,
      qpack_limits~,
      handshake_timeout_ms~,
      shutdown_timeout_ms~,
    ) catch {
      @quic.QuicError::ConnectionClosed(_, _) if authenticated &&
        @http3.peer_closed_normally(packets.connection()) => ()
      err => raise err
    }
  }
  Ok({
    socket,
    admissions: { pending: Queue(kind=Blocking(1)), shutdown, },
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
  let peers = self.initials.get(source)
  let mut initial : (@quic.ConnectionId, @quic.ConnectionId)? = None
  let direct = if (bytes[0].to_int() & 0x80) == 0 {
    // The shared socket issues fixed-width 16-byte local IDs.
    if bytes.length() >= 17 && (bytes[0].to_int() & 0x40) != 0 {
      self.routes.get(bytes[1:17].to_owned())
    } else {
      None
    }
  } else if @quic.quic_long_header_fields(bytes)
    is Ok((1, destination, remote, kind, _, _)) {
    let id = destination.bytes()
    if kind == 0 && bytes.length() >= 1200 && id.length() >= 8 {
      initial = Some((destination, remote))
    }
    if kind == 0 && peers is Some(group) && group.get(id) is Some(peer) {
      Some(peer)
    } else {
      self.routes.get(id)
    }
  } else {
    None
  }
  // A reset can have an unrelated DCID, even one belonging to another peer.
  // The common single-peer address needs no scan on CID-routable traffic.
  if peers is Some(group) &&
    !(group.length() == 1 &&
    direct is Some(known) &&
    known.initial_key.0 == source) {
    for _, peer in group {
      if !(direct is Some(known) && physical_equal(peer, known)) &&
        peer.receive_reset(packet) {
        return
      }
    }
  }
  if direct is Some(peer) {
    // This listener admits a fixed remote endpoint per peer.
    if peer.initial_key.0 != source {
      return
    }
    // A saturated inbox can drop ordinary data. Deliver a recognized reset
    // directly so it can wake a stalled peer and discard its queued packets.
    if !peer.inbox.try_put(packet) {
      ignore(peer.receive_reset(packet))
    }
    return
  }
  guard initial is Some((destination, remote)) &&
    !self.admissions.shutdown.has_started() else {
    return
  }
  let id = destination.bytes()
  let peer = {
    socket: self.socket,
    inbox: Queue(kind=Blocking(self.inbox_capacity)),
    closed: false,
    routes: self.routes,
    owned: Set([]),
    initials: self.initials,
    initial_key: (source, id),
    packets: None,
  }
  let accepted = @server_api.AcceptedConnection::new(
    async fn() {
      try {
        // Allocate the CID and TLS state only after the supervisor grants a slot.
        let cid = @quic.ConnectionId::random(@tls_native.NativeEntropy::new()).unwrap_or_error()
        if !peer.reserve_route(cid) {
          raise @quic.QuicError::InvalidPacket("server connection ID collision")
        }
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
  self.initials.get_or_init(source, () => Map([]))[id] = peer
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
  if self.admissions.shutdown.has_started() {
    return Err(Closed)
  }
  self.serving = true
  defer {
    self.serving = false
    self.close()
  }
  @async_support.with_group_result(async fn(group) {
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
  on_request_error~ : (Int64, Error) -> Unit = (_, _) => (),
  limits~ : @types.Limits = @types.Limits::defaults(),
  qpack_limits~ : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params~ : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  pending_datagrams_per_peer~ : Int32 = 16,
  handshake_timeout_ms~ : Int32 = 10000,
  shutdown_timeout_ms~ : Int32 = 5000,
) -> Result[NativeHttp3Listener, @server_api.ServerError] {
  let budget = limits.max_buffer_bytes.to_int64()
  NativeHttp3Listener::bind(
    endpoint,
    policy,
    options,
    (_, io) => @service.serve_http3_connection(io, handler, on_request_error~),
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
