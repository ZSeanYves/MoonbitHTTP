///|
/// The Go workload probe checks protocol, status and bytes on each response.
async fn workload(
  request : @types.Request[@body.BodyStream],
) -> @types.Response[@body.BodyStream] {
  let headers = @types.HeaderMap::new()
  let (chunk, chunks) = match (request.http_method, request.uri.path) {
    (Get, "/json") => {
      headers.append_string("content-type", "application/json").unwrap()
      (b"{\"ok\":true}", 1)
    }
    (Post, "/upload") => {
      let mut received = 0
      while request.body.next_frame() is Some(frame) {
        if frame is Data(bytes) {
          for byte in bytes {
            guard byte == b'x' else { fail("upload byte mismatch") }
          }
          received += bytes.length()
        }
      }
      (@utf8.encode(received.to_string()), 1)
    }
    (Get, "/download") => (Bytes::make(4096, b'x'), 16)
    _ => fail("unknown workload")
  }
  let mut remaining = chunks
  let body = @body.BodyStream::from_pull(
    fn() {
      if remaining == 0 {
        return None
      }
      remaining -= 1
      Some(Data(chunk))
    },
    size_hint=@body.SizeHint::exact(chunks * chunk.length()),
  )
  { status: 200, version: request.version, headers, body, }
}
