///|
pub(all) struct ClientResponse {
  response : @types.Response[Bytes]
  trailers : @types.HeaderMap?
}

///|
pub struct ClientConnection[R, W] {
  reader : R
  writer : W
  limits : @types.Limits
  read_size : Int
  read_timeout_ms : Int?
  write_timeout_ms : Int?
  mut closed : Bool
}

///|
pub fn[R, W] ClientConnection::new(
  reader : R,
  writer : W,
  limits? : @types.Limits = @types.Limits::defaults(),
  read_size? : Int = 8192,
  read_timeout_ms? : Int,
  write_timeout_ms? : Int,
) -> ClientConnection[R, W] {
  {
    reader,
    writer,
    limits,
    read_size,
    read_timeout_ms,
    write_timeout_ms,
    closed: false,
  }
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer] ClientConnection::send(
  self : ClientConnection[R, W],
  request : @types.Request[Bytes],
) -> ClientResponse {
  if self.closed {
    raise @http1.Http1Error::UnexpectedEof("client connection is closed")
  }
  let framing = @http1.BodyFraming::ContentLength(request.body.length())
  let request_head : @types.Request[Unit] = {
    http_method: request.http_method,
    uri: request.uri,
    version: request.version,
    headers: request.headers,
    body: (),
  }
  let encoded_head = match @http1.encode_request_head(request_head, framing) {
    Ok(bytes) => bytes
    Err(error) => raise error
  }
  write_with_timeout(self.writer, encoded_head, self.write_timeout_ms)
  if !request.body.is_empty() {
    write_with_timeout(self.writer, request.body, self.write_timeout_ms)
  }
  let decoder = @http1.ResponseDecoder::new(
    request.http_method,
    limits=self.limits,
  )
  let mut response_head : @types.Response[Unit]? = None
  let response_body : Array[Byte] = []
  let mut trailers : @types.HeaderMap? = None
  while true {
    match decoder.next() {
      Err(error) => raise error
      Ok(Some(ResponseHead(value))) =>
        if value.status >= 100 && value.status < 200 && value.status != 101 {
          response_head = None
        } else {
          response_head = Some(value)
        }
      Ok(Some(ResponseData(data))) => copy_data(response_body, data)
      Ok(Some(ResponseTrailers(value))) => trailers = Some(value)
      Ok(Some(ResponseEnd)) =>
        if response_head is Some(value) {
          let response = value.map_body(fn(_) {
            Bytes::from_array(response_body)
          })
          if header_has_token(response.headers, "connection", "close") {
            self.closed = true
          }
          return { response, trailers }
        }
      Ok(None) =>
        match
          read_some_with_timeout(
            self.reader,
            self.read_size,
            self.read_timeout_ms,
          ) {
          Some(bytes) =>
            match decoder.feed(bytes) {
              Ok(_) => ()
              Err(error) => raise error
            }
          None => {
            self.closed = true
            decoder.finish_input()
          }
        }
    }
  } nobreak {
    raise @http1.Http1Error::UnexpectedEof("client response loop ended")
  }
}
