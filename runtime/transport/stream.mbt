///|
priv enum StreamState {
  Open
  Finishing
  Closed
}

///|
pub struct StreamConnection {
  priv read_fn : async (Int) -> Result[Bytes?, TransportError]
  priv write_fn : async (Bytes) -> Result[Unit, TransportError]
  priv close_fn : () -> Unit
  priv finish_fn : async () -> Result[Unit, TransportError]
  priv endpoint : Endpoint
  priv mut state : StreamState
}

///|
pub fn StreamConnection::new(
  endpoint : Endpoint,
  read : async (Int) -> Result[Bytes?, TransportError],
  write : async (Bytes) -> Result[Unit, TransportError],
  close : () -> Unit,
  finish? : async () -> Result[Unit, TransportError] = fn() { Ok(()) },
) -> StreamConnection {
  {
    read_fn: read,
    write_fn: write,
    close_fn: close,
    finish_fn: finish,
    endpoint,
    state: Open,
  }
}

///|
pub async fn StreamConnection::read(
  self : StreamConnection,
  max_bytes : Int,
) -> Result[Bytes?, TransportError] {
  guard self.state is Open else { return Err(Closed) }
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
  guard self.state is Open else { return Err(Closed) }
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
/// Finishes pending protocol shutdown and releases the underlying stream.
/// The owning task calls this after its last write. Concurrent close aborts
/// a pending finish. Cancellation and flush errors still release the stream.
pub async fn StreamConnection::finish(
  self : StreamConnection,
) -> Result[Unit, TransportError] {
  match self.state {
    Closed => return Ok(())
    Finishing => return Err(Closed)
    Open => self.state = Finishing
  }
  defer self.close()
  match (self.finish_fn)() {
    Ok(_) if self.state is Closed => Err(Closed)
    result => result
  }
}

///|
pub fn StreamConnection::close(self : StreamConnection) -> Unit {
  if !self.is_closed() {
    self.state = Closed
    (self.close_fn)()
  }
}

///|
pub fn StreamConnection::endpoint(self : StreamConnection) -> Endpoint {
  self.endpoint
}

///|
pub fn StreamConnection::is_closed(self : StreamConnection) -> Bool {
  self.state is Closed
}

///|
pub(open) trait StreamConnector {
  async fn connect(Self, Endpoint, ConnectOptions) -> Result[
    StreamConnection,
    TransportError,
  ]
}
