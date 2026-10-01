///|
#warnings("-unnecessary_annotation")
pub struct TcpConnector {
  /// Native TCP adapter for explicitly resolved numeric endpoints. Host socket
  /// errors become transport errors at this boundary.
  keep_alive : Bool
}

///|
pub fn TcpConnector::new(keep_alive? : Bool = true) -> TcpConnector {
  { keep_alive, }
}

///|
pub impl @transport_api.StreamConnector for TcpConnector with fn connect(
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
    return Err(Unsupported(Connect))
  }
  let remote = match numeric_socket_addr(endpoint) {
    Some(value) => value
    None => return Err(Failed(Resolve, "TCP requires a numeric endpoint"))
  }
  let tcp = match
    native_io(Connect, options.timeout_ms, async fn() {
      @socket.Tcp::connect(remote)
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if self.keep_alive {
    tcp.enable_keepalive() catch {
      error => {
        tcp.close()
        return Err(native_transport_error(Connect, error))
      }
    }
  }
  let idle_timeout = options.idle_timeout_ms
  let connection = @transport_api.StreamConnection::new(
    endpoint,
    async fn(max_bytes) {
      native_io(Receive, idle_timeout, async fn() {
        tcp.read_some(max_len=max_bytes)
      })
    },
    async fn(bytes) {
      native_io(Send, idle_timeout, async fn() { tcp.write(bytes) })
    },
    fn() { tcp.close() },
  )
  Ok(connection)
}
