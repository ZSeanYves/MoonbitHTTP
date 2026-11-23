///|
/// Context for connection-specific field restrictions in HTTP/2 and HTTP/3.
pub(all) enum Section {
  Request
  Response
  Trailers
}

///|
fn is_trailers(value : BytesView) -> Bool {
  let lower = b"trailers"
  let upper = b"TRAILERS"
  if value.length() != lower.length() {
    return false
  }
  for i in 0..<lower.length() {
    let byte = value[i]
    if byte != lower[i] && byte != upper[i] {
      return false
    }
  }
  true
}

///|
/// Accepts a regular field after name/value syntax checks. Names are lowercase.
/// RFC 9113 §8.2.2 and RFC 9114 §4.2 restrict TE to request headers.
pub fn Section::allows(
  self : Section,
  name : String,
  value : BytesView,
) -> Bool {
  match name {
    "connection"
    | "proxy-connection"
    | "keep-alive"
    | "transfer-encoding"
    | "upgrade" => false
    "te" => self is Request && is_trailers(value)
    "content-length" | "host" | "trailer" => !(self is Trailers)
    _ => true
  }
}
