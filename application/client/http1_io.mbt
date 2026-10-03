///|
priv suberror Http1PooledIoError {
  Http1PooledIoError(@transport.TransportError)
} derive(Debug)

///|
#warnings("-alert_internal")
priv struct Http1StreamIo {
  reader_buffer : @aio.ReaderBuffer
  connection : @transport.StreamConnection
}

///|
#warnings("-alert_internal")
fn Http1StreamIo::new(
  connection : @transport.StreamConnection,
) -> Http1StreamIo {
  { reader_buffer: @aio.ReaderBuffer::new(), connection, }
}

///|
#warnings("-alert_internal")
impl @aio.Reader for Http1StreamIo with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
#warnings("-alert_internal")
impl @aio.Reader for Http1StreamIo with fn _direct_read(
  self,
  destination,
  offset~,
  max_len~,
) {
  match self.connection.read(max_len) {
    Err(error) => raise Http1PooledIoError(error)
    Ok(None) => 0
    Ok(Some(bytes)) => {
      if bytes.is_empty() {
        raise Http1PooledIoError(
          Failed(Receive, "stream returned an empty non-EOF read"),
        )
      }
      for index in 0..<bytes.length() {
        destination[offset + index] = bytes[index]
      }
      bytes.length()
    }
  }
}

///|
#warnings("-alert_internal")
impl @aio.Writer for Http1StreamIo with fn write_once(
  self,
  source,
  offset~,
  len~,
) {
  let bytes = source[offset:offset + len].to_owned()
  match self.connection.write(bytes) {
    Ok(_) => len
    Err(error) => raise Http1PooledIoError(error)
  }
}

///|
priv struct Http1PooledSession {
  connection : @transport.StreamConnection
  protocol : @service.ClientConnection[Http1StreamIo, Http1StreamIo]
  proxy_target : @types.Endpoint?
}

///|
fn Http1PooledSession::new(
  connection : @transport.StreamConnection,
  options : RequestOptions,
  proxy_target? : @types.Endpoint? = None,
) -> Result[Http1PooledSession, ClientError] {
  let io = Http1StreamIo::new(connection)
  let protocol = match
    @service.ClientConnection::new(
      io,
      io,
      limits=options.limits,
      read_size=options.limits.max_buffer_bytes.min(8192),
      request_headers_timeout_ms=options.timeouts.request_headers_ms,
      request_body_timeout_ms=options.timeouts.request_body_ms,
      response_headers_timeout_ms=options.timeouts.response_headers_ms,
      response_body_timeout_ms=options.timeouts.response_body_ms,
    ) {
    Ok(value) => value
    Err(_) => {
      connection.close()
      return Err(ClientInvalidOptions("invalid HTTP/1 session configuration"))
    }
  }
  Ok({ connection, protocol, proxy_target, })
}

///|
fn Http1PooledSession::proxy_target(
  self : Http1PooledSession,
) -> @types.Endpoint? {
  self.proxy_target
}

///|
fn Http1PooledSession::close(self : Http1PooledSession) -> Unit {
  self.protocol.close()
  self.connection.close()
}

///|
fn Http1PooledSession::is_reusable(self : Http1PooledSession) -> Bool {
  self.protocol.is_reusable() && !self.connection.is_closed()
}
