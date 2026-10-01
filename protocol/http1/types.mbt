///|
pub(all) suberror Http1Error {
  InvalidStartLine(String)
  InvalidHeader(String)
  InvalidFraming(String)
  LimitExceeded(String)
  UnexpectedEof(String)
} derive(Debug, Eq)

///|
pub(all) enum BodyFraming {
  NoBody
  ContentLength(Int)
  Chunked
  CloseDelimited
} derive(Debug, Eq)

///|
pub(all) enum RequestEvent {
  RequestHead(@types.Request[Unit])
  RequestData(Bytes)
  RequestTrailers(@types.HeaderMap)
  RequestEnd
}

///|
pub(all) enum ResponseEvent {
  ResponseHead(@types.Response[Unit])
  ResponseData(Bytes)
  ResponseTrailers(@types.HeaderMap)
  ResponseEnd
}
