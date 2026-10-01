///|
pub struct StreamConnection {
  priv read_fn : async (Int) -> Result[Bytes?, TransportError]
  priv write_fn : async (Bytes) -> Result[Unit, TransportError]
  priv close_fn : () -> Unit
  priv endpoint : Endpoint
  priv mut closed : Bool
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
  errdefer self.close()
  guard max_bytes > 0 else {
    return Err(Failed(Receive, "read size must be positive"))
  }
  let result = (self.read_fn)(max_bytes)
  match result {
    Ok(Some(bytes)) if bytes.length() > max_bytes => {
      self.close()
      Err(Failed(Receive, "reader returned more bytes than requested"))
    }
    Err(error) => {
      self.close()
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
  errdefer self.close()
  let result = (self.write_fn)(bytes)
  match result {
    Err(error) => {
      self.close()
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
