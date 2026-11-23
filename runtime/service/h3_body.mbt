///|
priv struct H3IncomingBody {
  io : H3ConnectionIo
  id : Int64
  chunks : @deque.Deque[Bytes]
  mut buffered_bytes : Int
  changed : @cond_var.Cond
  mut trailers : @types.HeaderMap?
  mut finished : Bool
  mut failure : Error?
}

///|
fn H3IncomingBody::new(io : H3ConnectionIo, id : Int64) -> H3IncomingBody {
  {
    io,
    id,
    chunks: @deque.from_array([]),
    buffered_bytes: 0,
    changed: Cond(),
    trailers: None,
    finished: false,
    failure: None,
  }
}

///|
fn H3IncomingBody::discard(
  self : H3IncomingBody,
  reason? : Error = @body.BodyError::Cancelled,
) -> Unit {
  if self.failure is Some(_) {
    return
  }
  self.failure = Some(reason)
  // Release retained data even if an application kept the body handle.
  let count = self.buffered_bytes
  self.chunks.clear()
  self.buffered_bytes = 0
  ignore(self.io.session.consume_body(self.id, count))
  self.trailers = None
  self.changed.broadcast()
}

///|
// Keep the decoder's chunks and charge their bytes until a consumer reads
// them. Empty DATA frames take no queue entries.
fn H3IncomingBody::offer(self : H3IncomingBody, data : Bytes) -> Bool {
  if data.length() > self.io.limits.max_buffer_bytes - self.buffered_bytes {
    return false
  }
  if !data.is_empty() {
    self.chunks.push_back(data)
    self.buffered_bytes += data.length()
    self.changed.signal()
  }
  true
}

///|
async fn H3IncomingBody::read(self : H3IncomingBody) -> @body.Frame? {
  while self.failure is None && self.chunks.is_empty() && !self.finished {
    self.changed.wait()
  }
  if self.failure is Some(error) {
    raise error
  }
  if self.chunks.pop_front() is Some(data) {
    self.buffered_bytes -= data.length()
    h3_io_value(self.io.session.consume_body(self.id, data.length()))
    return Some(Data(data))
  }
  // Deliver trailers only after FIN has validated the final body length.
  self.trailers.map(headers => Trailers(headers))
}

///|
async fn H3ConnectionIo::write_when_ready(
  self : H3ConnectionIo,
  write : () -> Result[Unit, @http3.Http3Error],
) -> Unit {
  while true {
    match write() {
      Ok(_) => {
        self.flush()
        return
      }
      Err(Http3WriteBlocked) => self.write_changed.wait()
      Err(error) => raise error
    }
  }
}

///|
fn h3_fields(headers : @types.HeaderMap) -> Array[@http3.QpackField] {
  headers
  .fields()
  .map(f => { name: f.name.value, value: f.value.bytes, sensitive: false, })
}

///|
async fn[B : @body.Body] H3ConnectionIo::write_body(
  self : H3ConnectionIo,
  id : Int64,
  body : B,
) -> Unit {
  // DATA uses a one-byte type and at most a two-byte length at this chunk size.
  let chunk_size = (self.limits.max_buffer_bytes - 3).max(1).min(16383)
  while body.next_frame() is Some(frame) {
    match frame {
      Data(bytes) => {
        let mut offset = 0
        while offset < bytes.length() {
          let count = (bytes.length() - offset).min(chunk_size)
          let chunk = if count == bytes.length() {
            bytes
          } else {
            bytes[offset:offset + count].to_owned()
          }
          self.write_when_ready(fn() { self.session.send_data(id, chunk) })
          offset += count
        }
      }
      Trailers(headers) => {
        let fields = h3_fields(headers)
        self.write_when_ready(fn() { self.session.send_headers(id, fields) })
      }
    }
  }
  self.write_when_ready(fn() { self.session.finish(id) })
}
