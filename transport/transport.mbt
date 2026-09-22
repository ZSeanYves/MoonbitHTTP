///|
pub(all) enum TransportOperation {
  Resolve
  Connect
  Accept
  Send
  Receive
  Close
  ProxyConnect
  QuicEndpoint
} derive(Eq, Debug)

///|
pub(all) struct Endpoint {
  scheme : String
  host : String
  port : Int
} derive(Eq, Debug, Compare, Hash)

///|
pub(all) suberror EndpointError {
  InvalidScheme
  InvalidHost
  InvalidPort
} derive(Eq, Debug)

///|
fn endpoint_ascii_lower(value : String) -> String {
  let bytes = @utf8.encode(value)
  let out = FixedArray::make(bytes.length(), b'0')
  for i in 0..<bytes.length() {
    let byte = bytes[i]
    out[i] = if byte >= b'A' && byte <= b'Z' {
      (byte.to_int() + 32).to_byte()
    } else {
      byte
    }
  }
  @utf8.decode(out.unsafe_reinterpret_as_bytes()) catch {
    _ => ""
  }
}

///|
fn valid_scheme(value : String) -> Bool {
  let bytes = @utf8.encode(value)
  guard !bytes.is_empty() else { return false }
  for i, byte in bytes {
    let alpha = (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z')
    let digit = byte >= b'0' && byte <= b'9'
    if i == 0 {
      if !alpha {
        return false
      }
    } else if !alpha && !digit && byte != b'+' && byte != b'-' && byte != b'.' {
      return false
    }
  }
  true
}

///|
fn valid_host(value : String) -> Bool {
  let bytes = @utf8.encode(value)
  guard !bytes.is_empty() else { return false }
  // A host passed to this capability is already split from its port.  A colon
  // is therefore valid only as part of an IPv6 literal; accepting
  // `example.test:443` here would make policy and connector authorities
  // disagree about the destination.
  if value.contains(":") {
    return valid_ipv6(bytes)
  }
  for byte in bytes {
    let n = byte.to_int()
    if n <= 0x20 ||
      n == 0x7f ||
      byte == b'/' ||
      byte == b'\\' ||
      byte == b'@' ||
      byte == b'?' ||
      byte == b'#' {
      return false
    }
  }
  true
}

///|
pub fn Endpoint::new(
  scheme : String,
  host : String,
  port : Int,
) -> Result[Endpoint, EndpointError] {
  guard valid_scheme(scheme) else { return Err(InvalidScheme) }
  let normalized_host = if host.has_prefix("[") {
    if !host.has_suffix("]") || host.length() <= 2 {
      return Err(InvalidHost)
    }
    host[1:host.length() - 1].to_owned()
  } else {
    host
  }
  if host.has_prefix("[") && !valid_ipv6(@utf8.encode(normalized_host)) {
    return Err(InvalidHost)
  }
  guard valid_host(normalized_host) else { return Err(InvalidHost) }
  guard port > 0 && port <= 65535 else { return Err(InvalidPort) }
  Ok({
    scheme: endpoint_ascii_lower(scheme),
    host: endpoint_ascii_lower(normalized_host),
    port,
  })
}

///|
pub fn Endpoint::scheme(self : Endpoint) -> String {
  self.scheme
}

///|
pub fn Endpoint::host(self : Endpoint) -> String {
  self.host
}

///|
pub fn Endpoint::port(self : Endpoint) -> Int {
  self.port
}

///|
pub fn Endpoint::authority(self : Endpoint) -> String {
  let host = self.host
  let rendered = if host.contains(":") && !host.has_prefix("[") {
    "[" + host + "]"
  } else {
    host
  }
  rendered + ":" + self.port.to_string()
}

///|
pub(all) struct ConnectOptions {
  timeout_ms : Int?
  idle_timeout_ms : Int?
  local_host : String?
  local_port : Int?
} derive(Debug, Eq)

///|
pub(all) suberror ConnectOptionsError {
  InvalidTimeout
  InvalidLocalPort
  InvalidLocalHost
} derive(Debug, Eq)

///|
pub fn ConnectOptions::defaults() -> ConnectOptions {
  {
    timeout_ms: Some(10000),
    idle_timeout_ms: Some(60000),
    local_host: None,
    local_port: None,
  }
}

///|
pub fn ConnectOptions::validate(
  self : ConnectOptions,
) -> Result[Unit, ConnectOptionsError] {
  match self.timeout_ms {
    Some(value) if value <= 0 => return Err(InvalidTimeout)
    _ => ()
  }
  match self.idle_timeout_ms {
    Some(value) if value <= 0 => return Err(InvalidTimeout)
    _ => ()
  }
  match self.local_port {
    Some(value) if value < 0 || value > 65535 => return Err(InvalidLocalPort)
    _ => ()
  }
  match self.local_host {
    Some(value) if !valid_host(value) => return Err(InvalidLocalHost)
    _ => ()
  }
  Ok(())
}

///|
pub(all) suberror TransportError {
  InvalidEndpoint(EndpointError)
  InvalidOptions(ConnectOptionsError)
  Failed(TransportOperation, String)
  Closed
  Timeout(TransportOperation)
  Cancelled
  Unsupported(TransportOperation)
  InvalidDatagramSize
  InvalidResolveOptions
} derive(Debug, Eq)

///|
pub(all) struct StreamConnection {
  read_fn : async (Int) -> Result[Bytes?, TransportError]
  write_fn : async (Bytes) -> Result[Unit, TransportError]
  close_fn : () -> Unit
  endpoint : Endpoint
  mut closed : Bool
}

///|
pub fn StreamConnection::new(
  endpoint : Endpoint,
  read : async (Int) -> Result[Bytes?, TransportError],
  write : async (Bytes) -> Result[Unit, TransportError],
  close : () -> Unit,
) -> StreamConnection {
  { read_fn: read, write_fn: write, close_fn: close, endpoint, closed: false, }
}

///|
pub async fn StreamConnection::read(
  self : StreamConnection,
  max_bytes : Int,
) -> Result[Bytes?, TransportError] {
  guard !self.closed else { return Err(Closed) }
  guard max_bytes > 0 else {
    return Err(Failed(Receive, "read size must be positive"))
  }
  let result = (self.read_fn)(max_bytes)
  match result {
    Ok(Some(bytes)) if bytes.length() > max_bytes => {
      (self.close_fn)()
      self.closed = true
      Err(Failed(Receive, "reader returned more bytes than requested"))
    }
    Err(error) => {
      (self.close_fn)()
      self.closed = true
      Err(error)
    }
    _ => result
  }
}

///|
pub async fn StreamConnection::write(
  self : StreamConnection,
  bytes : Bytes,
) -> Result[Unit, TransportError] {
  guard !self.closed else { return Err(Closed) }
  let result = (self.write_fn)(bytes)
  match result {
    Err(error) => {
      (self.close_fn)()
      self.closed = true
      Err(error)
    }
    _ => result
  }
}

///|
pub fn StreamConnection::close(self : StreamConnection) -> Unit {
  if !self.closed {
    self.closed = true
    (self.close_fn)()
  }
}

///|
pub fn StreamConnection::endpoint(self : StreamConnection) -> Endpoint {
  self.endpoint
}

///|
pub fn StreamConnection::is_closed(self : StreamConnection) -> Bool {
  self.closed
}

///|
pub(open) trait StreamConnector {
  async fn connect(Self, Endpoint, ConnectOptions) -> Result[
    StreamConnection,
    TransportError,
  ]
}

///|
pub(all) struct Datagram {
  payload : Bytes
  endpoint : Endpoint
} derive(Debug, Eq)

///|
pub fn Datagram::new(payload : Bytes, endpoint : Endpoint) -> Datagram {
  { payload, endpoint, }
}

///|
pub fn Datagram::payload(self : Datagram) -> Bytes {
  self.payload
}

///|
pub fn Datagram::endpoint(self : Datagram) -> Endpoint {
  self.endpoint
}

///|
pub(open) trait DatagramSocket {
  async fn send(Self, Endpoint, Bytes) -> Result[Unit, TransportError]
  async fn receive(Self, Int) -> Result[Datagram, TransportError]
  fn close(Self) -> Unit
}

///|
pub(all) struct ResolveOptions {
  timeout_ms : Int?
  max_results : Int
} derive(Debug, Eq)

///|
pub fn ResolveOptions::defaults() -> ResolveOptions {
  { timeout_ms: Some(10000), max_results: 16, }
}

///|
pub fn ResolveOptions::validate(
  self : ResolveOptions,
) -> Result[Unit, TransportError] {
  match self.timeout_ms {
    Some(value) if value <= 0 => return Err(InvalidResolveOptions)
    _ => ()
  }
  if self.max_results <= 0 {
    return Err(InvalidResolveOptions)
  }
  Ok(())
}

///|
pub(all) struct IpAddress {
  value : String
} derive(Debug, Eq, Compare)

///|
fn valid_ipv4_octet(input : BytesView) -> Bool {
  if input.is_empty() || input.length() > 3 {
    return false
  }
  if input.length() > 1 && input[0] == b'0' {
    return false
  }
  let mut value = 0
  for byte in input {
    if byte < b'0' || byte > b'9' {
      return false
    }
    value = value * 10 + byte.to_int() - 48
  }
  value <= 255
}

///|
fn valid_ipv4(input : BytesView) -> Bool {
  let mut start = 0
  let mut octets = 0
  for index in 0..<=input.length() {
    if index == input.length() || input[index] == b'.' {
      if !valid_ipv4_octet(input[start:index]) {
        return false
      }
      octets += 1
      start = index + 1
    }
  }
  octets == 4
}

///|
fn valid_ipv6_group(input : BytesView) -> Bool {
  if input.is_empty() || input.length() > 4 {
    return false
  }
  for byte in input {
    let digit = byte >= b'0' && byte <= b'9'
    let lower = byte >= b'a' && byte <= b'f'
    let upper = byte >= b'A' && byte <= b'F'
    if !digit && !lower && !upper {
      return false
    }
  }
  true
}

///|
fn valid_ipv6(input : BytesView) -> Bool {
  if input.is_empty() {
    return false
  }
  let mut index = 0
  let mut groups = 0
  let mut compressed = false
  if input[0] == b':' {
    if input.length() < 2 || input[1] != b':' {
      return false
    }
    compressed = true
    index = 2
    if index == input.length() {
      return true
    }
  }
  while index < input.length() {
    let start = index
    while index < input.length() && input[index] != b':' {
      index += 1
    }
    if start == index {
      return false
    }
    let group = input[start:index]
    let mut ipv4_tail = false
    for byte in group {
      if byte == b'.' {
        ipv4_tail = true
        break
      }
    }
    if ipv4_tail {
      if index != input.length() || !valid_ipv4(group) {
        return false
      }
      groups += 2
    } else {
      if !valid_ipv6_group(group) {
        return false
      }
      groups += 1
    }
    if groups > 8 {
      return false
    }
    if index == input.length() {
      break
    }
    if index + 1 < input.length() && input[index + 1] == b':' {
      if compressed {
        return false
      }
      compressed = true
      index += 2
      if index == input.length() {
        break
      }
    } else {
      index += 1
      if index == input.length() {
        return false
      }
    }
  }
  if compressed {
    groups < 8
  } else {
    groups == 8
  }
}

///|
pub fn IpAddress::parse(value : String) -> Result[IpAddress, TransportError] {
  let bytes = @utf8.encode(value)
  if !valid_ipv4(bytes) && !valid_ipv6(bytes) {
    return Err(Failed(Resolve, "invalid numeric IP address"))
  }
  Ok({ value: endpoint_ascii_lower(value), })
}

///|
pub fn IpAddress::value(self : IpAddress) -> String {
  self.value
}

///|
pub(open) trait NameResolver {
  async fn resolve(Self, String, ResolveOptions) -> Result[
    Array[IpAddress],
    TransportError,
  ]
}

///|
pub struct StaticResolver {
  entries : Map[String, Array[IpAddress]]
}

///|
pub fn StaticResolver::new(
  entries : Array[(String, Array[IpAddress])],
) -> StaticResolver {
  let map = Map([])
  for (host, addresses) in entries {
    map.set(endpoint_ascii_lower(host), addresses.copy())
  }
  { entries: map, }
}

///|
pub impl NameResolver for StaticResolver with fn resolve(self, host, options) {
  match options.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.entries.get(endpoint_ascii_lower(host)) {
    Some(addresses) =>
      Ok(addresses[:addresses.length().min(options.max_results)].to_owned())
    None => Err(Failed(Resolve, "host was not found by resolver"))
  }
}

///|
pub(all) enum PolicyOperation {
  Resolve
  Connect
  Redirect
  ProxyConnect
  QuicEndpoint
} derive(Eq, Debug)

///|
pub(all) suberror PolicyError {
  Denied(PolicyOperation, String)
  InvalidRule(String)
} derive(Eq, Debug)

///|
pub(open) trait NetworkPolicy {
  fn authorize(Self, Endpoint, PolicyOperation) -> Result[Unit, PolicyError]
}

///|
pub struct AllowAllPolicy(Unit)

///|
pub fn AllowAllPolicy::new() -> AllowAllPolicy {
  AllowAllPolicy(())
}

///|
pub impl NetworkPolicy for AllowAllPolicy with fn authorize(
  _self,
  _endpoint,
  _operation,
) {
  Ok(())
}

///|
pub struct DenyAllPolicy(Unit)

///|
pub fn DenyAllPolicy::new() -> DenyAllPolicy {
  DenyAllPolicy(())
}

///|
pub impl NetworkPolicy for DenyAllPolicy with fn authorize(
  _self,
  _endpoint,
  operation,
) {
  Err(Denied(operation, "network policy denied operation"))
}

///|
pub(open) trait Clock {
  fn monotonic_millis(Self) -> Int64
  fn wall_clock_seconds(Self) -> Int64
}

///|
pub(open) trait Entropy {
  fn fill(Self, FixedArray[Byte]) -> Result[Unit, EntropyError]
}

///|
pub(all) suberror EntropyError {
  Unavailable
  Failed(String)
  InvalidBuffer
} derive(Eq, Debug)

///|
pub(all) struct FixedClock {
  mut monotonic : Int64
  mut wall_seconds : Int64
} derive(Debug, Eq)

///|
pub fn FixedClock::new(monotonic : Int64, wall_seconds : Int64) -> FixedClock {
  { monotonic, wall_seconds, }
}

///|
pub impl Clock for FixedClock with fn monotonic_millis(self) {
  self.monotonic
}

///|
pub impl Clock for FixedClock with fn wall_clock_seconds(self) {
  self.wall_seconds
}

///|
pub fn FixedClock::advance(
  self : FixedClock,
  millis : Int64,
) -> Result[Unit, String] {
  guard millis >= 0 else { return Err("clock cannot move backwards") }
  self.monotonic += millis
  self.wall_seconds += millis / 1000
  Ok(())
}

///|
pub struct ZeroEntropy(Unit)

///|
pub fn ZeroEntropy::new() -> ZeroEntropy {
  ZeroEntropy(())
}

///|
pub impl Entropy for ZeroEntropy with fn fill(_self, buffer) {
  for i in 0..<buffer.length() {
    buffer[i] = 0
  }
  Ok(())
}

///|
/// Deterministic datagram substitute used by protocol tests and Wasm hosts.
/// It has an explicit size limit and never silently truncates a datagram.
pub struct MemoryDatagramSocket {
  inbound : @aqueue.Queue[Datagram]
  sent : Array[Datagram]
  max_datagram_size : Int
  mut closed : Bool
}

///|
pub fn MemoryDatagramSocket::new(
  max_datagram_size? : Int = 65527,
) -> Result[MemoryDatagramSocket, TransportError] {
  if max_datagram_size <= 0 {
    return Err(InvalidDatagramSize)
  }
  Ok({
    inbound: Queue(kind=Blocking(64)),
    sent: [],
    max_datagram_size,
    closed: false,
  })
}

///|
pub fn MemoryDatagramSocket::inject(
  self : MemoryDatagramSocket,
  datagram : Datagram,
) -> Result[Unit, TransportError] {
  if self.closed {
    return Err(Closed)
  }
  if datagram.payload.length() > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  let accepted = self.inbound.try_put(datagram) catch { _ => false }
  if !accepted {
    return Err(Failed(Receive, "memory datagram queue is full"))
  }
  Ok(())
}

///|
pub fn MemoryDatagramSocket::sent(
  self : MemoryDatagramSocket,
) -> Array[Datagram] {
  self.sent.copy()
}

///|
pub impl DatagramSocket for MemoryDatagramSocket with fn send(
  self,
  endpoint,
  payload,
) {
  if self.closed {
    return Err(Closed)
  }
  if payload.length() > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  self.sent.push({ payload, endpoint, })
  Ok(())
}

///|
pub impl DatagramSocket for MemoryDatagramSocket with fn receive(
  self,
  max_bytes,
) {
  if self.closed {
    return Err(Closed)
  }
  if max_bytes <= 0 || max_bytes > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  let datagram = self.inbound.get() catch { _ => return Err(Closed) }
  if datagram.payload.length() > max_bytes {
    return Err(InvalidDatagramSize)
  }
  Ok(datagram)
}

///|
pub impl DatagramSocket for MemoryDatagramSocket with fn close(self) {
  if !self.closed {
    self.closed = true
    self.inbound.close(error=Closed, clear=true)
  }
}
