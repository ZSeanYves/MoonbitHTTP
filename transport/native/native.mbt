///|
#warnings("-unnecessary_annotation")
pub struct TcpConnector {
  /// Native TCP capability adapter. Host socket errors are caught at this
  /// boundary and become transport errors; protocol packages never import the
  /// async socket FFI directly.
  keep_alive : Bool
}

///|
pub fn TcpConnector::new(keep_alive? : Bool = true) -> TcpConnector {
  { keep_alive, }
}

///|
fn native_tcp_error(
  operation : @transport.TransportOperation,
) -> @transport.TransportError {
  Failed(operation, "native TCP operation failed")
}

///|
fn numeric_socket_addr(endpoint : @transport.Endpoint) -> @socket.Addr? {
  guard @transport.IpAddress::parse(endpoint.host()) is Ok(_) else {
    return None
  }
  Some(@socket.Addr::parse(endpoint.authority()) catch { _ => return None })
}

///|
async fn connect_native_tcp(endpoint : @transport.Endpoint) -> @socket.Tcp {
  match numeric_socket_addr(endpoint) {
    Some(address) => @socket.Tcp::connect(address)
    None => @socket.Tcp::connect_to_host(endpoint.host(), port=endpoint.port())
  }
}

///|
pub impl @transport.StreamConnector for TcpConnector with fn connect(
  self,
  endpoint,
  options,
) {
  match options.validate() {
    Ok(_) => ()
    Err(error) => return Err(InvalidOptions(error))
  }
  // Local bind options are rejected instead of being silently ignored by this
  // adapter. Numeric endpoints bypass hostname resolution so a policy-checked
  // DNS result cannot be rebound between authorization and connect.
  if options.local_host is Some(_) || options.local_port is Some(_) {
    return Err(native_tcp_error(Connect))
  }
  let tcp = match options.timeout_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, () => connect_native_tcp(endpoint)) catch {
        _ => return Err(Timeout(Connect))
      }
    None =>
      connect_native_tcp(endpoint) catch {
        _ => return Err(native_tcp_error(Connect))
      }
  }
  if self.keep_alive {
    tcp.enable_keepalive() catch {
      _ => {
        tcp.close()
        return Err(native_tcp_error(Connect))
      }
    }
  }
  let idle_timeout = options.idle_timeout_ms
  let connection = @transport.StreamConnection::new(
    endpoint,
    async fn(max_bytes) {
      let result = match idle_timeout {
        Some(timeout) =>
          @async.with_timeout(timeout, () => tcp.read_some(max_len=max_bytes)) catch {
            _ => return Err(Timeout(Receive))
          }
        None =>
          tcp.read_some(max_len=max_bytes) catch {
            _ => return Err(native_tcp_error(Receive))
          }
      }
      Ok(result)
    },
    async fn(bytes) {
      match idle_timeout {
        Some(timeout) => {
          @async.with_timeout(timeout, () => tcp.write(bytes)) catch {
            _ => return Err(Timeout(Send))
          }
          Ok(())
        }
        None => {
          tcp.write(bytes) catch {
            _ => return Err(native_tcp_error(Send))
          }
          Ok(())
        }
      }
    },
    fn() { tcp.close() },
  )
  Ok(connection)
}

///|
/// Native hostname resolver. The async socket API exposes the first address
/// for each requested family, so this adapter returns at most one IPv4 and one
/// IPv6 address while still enforcing the caller's result bound.
pub struct NativeResolver(Unit)

///|
pub fn NativeResolver::new() -> NativeResolver {
  NativeResolver(())
}

///|
fn ip_from_socket_addr(address : @socket.Addr) -> @transport.IpAddress? {
  if !address.is_ipv6() {
    let value = address.ip()
    let literal = "\{value >> 24}.\{(value >> 16) & 255}.\{(value >> 8) & 255}.\{value & 255}"
    return match @transport.IpAddress::parse(literal) {
      Ok(address) => Some(address)
      Err(_) => None
    }
  }
  let rendered = address.to_string()
  guard rendered.has_prefix("[") else { return None }
  guard rendered.find("]") is Some(close) else { return None }
  let literal = rendered[1:close].to_owned()
  // Scoped IPv6 literals cannot currently be represented by IpAddress.
  guard !literal.contains("%") else { return None }
  match @transport.IpAddress::parse(literal) {
    Ok(address) => Some(address)
    Err(_) => None
  }
}

///|
async fn resolve_family(
  host : String,
  protocol : @socket.IpProtocolPreference,
) -> Result[@transport.IpAddress?, @transport.TransportError] {
  let address = @socket.Addr::resolve(host, port=0, protocol~) catch {
    error =>
      return if @async.is_cancellation_error(error) {
        Err(Cancelled)
      } else {
        Ok(None)
      }
  }
  Ok(ip_from_socket_addr(address))
}

///|
fn append_unique_address(
  addresses : Array[@transport.IpAddress],
  candidate : @transport.IpAddress?,
  max_results : Int,
) -> Unit {
  guard addresses.length() < max_results else { return }
  guard candidate is Some(candidate) else { return }
  for address in addresses {
    if address == candidate {
      return
    }
  }
  addresses.push(candidate)
}

///|
async fn resolve_native_host(
  host : String,
  max_results : Int,
) -> Result[Array[@transport.IpAddress], @transport.TransportError] {
  let addresses : Array[@transport.IpAddress] = []
  let ipv4 = match resolve_family(host, OnlyV4) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  append_unique_address(addresses, ipv4, max_results)
  if addresses.length() < max_results {
    let ipv6 = match resolve_family(host, OnlyV6) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    append_unique_address(addresses, ipv6, max_results)
  }
  if addresses.is_empty() {
    Err(Failed(Resolve, "hostname resolution failed"))
  } else {
    Ok(addresses)
  }
}

///|
pub impl @transport.NameResolver for NativeResolver with fn resolve(
  _self,
  host,
  options,
) {
  match options.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @transport.IpAddress::parse(host) {
    Ok(address) => return Ok([address])
    Err(_) => ()
  }
  match options.timeout_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, () => {
        resolve_native_host(host, options.max_results)
      }) catch {
        error =>
          if @async.is_cancellation_error(error) {
            Err(Cancelled)
          } else {
            Err(Timeout(Resolve))
          }
      }
    None => resolve_native_host(host, options.max_results)
  }
}

///|
/// Native clock with independent monotonic and wall-clock sources. Deadlines
/// use elapsed monotonic time; HTTP dates and cookie expiry use Unix time.
pub struct NativeClock {
  started : @bench.Timestamp
}

///|
pub fn NativeClock::new() -> NativeClock {
  { started: @bench.monotonic_clock_start(), }
}

///|
pub impl @transport.Clock for NativeClock with fn monotonic_millis(self) {
  (@bench.monotonic_clock_end(self.started) / 1000.0).to_int64()
}

///|
pub impl @transport.Clock for NativeClock with fn wall_clock_seconds(_self) {
  @env.now().reinterpret_as_int64() / 1000L
}

///|
/// A small UDP capability for one connected native endpoint. QUIC callers can
/// use `connect` to bind a local ephemeral socket and then pass the value to
/// the generic datagram driver.
pub struct UdpSocket {
  socket : @socket.UdpClient
  endpoint : @transport.Endpoint
  max_datagram_size : Int
  mut closed : Bool
}

///|
pub async fn UdpSocket::connect(
  endpoint : @transport.Endpoint,
  max_datagram_size? : Int = 65527,
) -> Result[UdpSocket, @transport.TransportError] {
  if max_datagram_size <= 0 || max_datagram_size > 65527 {
    return Err(InvalidDatagramSize)
  }
  let local_addr = @socket.Addr::parse("0.0.0.0:0") catch {
    _ => return Err(native_tcp_error(QuicEndpoint))
  }
  let udp = @socket.UdpClient::UdpClient(local_addr) catch {
    _ => return Err(native_tcp_error(QuicEndpoint))
  }
  let remote = @socket.Addr::parse(endpoint.authority()) catch {
    _ => {
      udp.close()
      return Err(native_tcp_error(QuicEndpoint))
    }
  }
  udp.connect(remote) catch {
    _ => {
      udp.close()
      return Err(native_tcp_error(Connect))
    }
  }
  Ok({ socket: udp, endpoint, max_datagram_size, closed: false, })
}

///|
pub impl @transport.DatagramSocket for UdpSocket with fn send(
  self,
  endpoint,
  payload,
) {
  if self.closed {
    return Err(Closed)
  }
  if endpoint != self.endpoint {
    return Err(native_tcp_error(Send))
  }
  if payload.length() > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  self.socket.send(payload) catch {
    _ => return Err(native_tcp_error(Send))
  }
  Ok(())
}

///|
pub impl @transport.DatagramSocket for UdpSocket with fn receive(
  self,
  max_bytes,
) {
  if self.closed {
    return Err(Closed)
  }
  if max_bytes <= 0 || max_bytes > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  let buffer = FixedArray::make(max_bytes, b'\x00')
  let (count, _) = self.socket.recvfrom(buffer) catch {
    _ => return Err(native_tcp_error(Receive))
  }
  if count < 0 || count > max_bytes {
    return Err(native_tcp_error(Receive))
  }
  let payload = FixedArray::make(count, b'\x00')
  for index in 0..<count {
    payload[index] = buffer[index]
  }
  Ok(
    @transport.Datagram::new(
      payload.unsafe_reinterpret_as_bytes(),
      self.endpoint,
    ),
  )
}

///|
pub impl @transport.DatagramSocket for UdpSocket with fn close(self) {
  if !self.closed {
    self.closed = true
    self.socket.close()
  }
}
