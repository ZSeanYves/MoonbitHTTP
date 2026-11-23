///|
priv suberror ClientStreamError {
  ClientStreamError(@transport.TransportError)
} derive(Debug)

///|
#warnings("-alert_internal")
priv struct ClientStreamIo {
  reader_buffer : @aio.ReaderBuffer
  connection : @transport.StreamConnection
}

///|
#warnings("-alert_internal")
fn ClientStreamIo::new(
  connection : @transport.StreamConnection,
) -> ClientStreamIo {
  { reader_buffer: @aio.ReaderBuffer::new(), connection, }
}

///|
#warnings("-alert_internal")
impl @aio.Reader for ClientStreamIo with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
#warnings("-alert_internal")
impl @aio.Reader for ClientStreamIo with fn _direct_read(
  self,
  destination,
  offset~,
  max_len~,
) {
  match self.connection.read(max_len) {
    Err(error) => raise ClientStreamError(error)
    Ok(None) => 0
    Ok(Some(bytes)) => {
      if bytes.is_empty() {
        raise ClientStreamError(
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
impl @aio.Writer for ClientStreamIo with fn write_once(
  self,
  source,
  offset~,
  len~,
) {
  let bytes = source[offset:offset + len].to_owned()
  match self.connection.write(bytes) {
    Ok(_) => len
    Err(error) => raise ClientStreamError(error)
  }
}

///|
async fn collect_client_response(
  response : @types.Response[@body.BodyStream],
  limit : Int,
) -> @types.Response[Bytes] {
  let (body, trailers) = @body.collect(response.body, max_bytes=limit)
  match trailers {
    Some(values) =>
      for field in values.fields() {
        response.headers.append(field.name, field.value)
      }
    None => ()
  }
  {
    status: response.status,
    version: response.version,
    headers: response.headers,
    body,
  }
}
