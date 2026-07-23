///|
/// A sequential HTTP/1 connection. A response body must be fully consumed
/// before the next request is sent on the same connection.
pub struct ClientConnection[R, W] {
  reader : R
  writer : W
  limits : @types.Limits
  read_size : Int
  read_timeout_ms : Int?
  write_timeout_ms : Int?
  mut closed : Bool
  mut busy : Bool
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
    busy: false,
  }
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] ClientConnection::send(
  self : ClientConnection[R, W],
  request : @types.Request[B],
) -> @types.Response[@body.BodyStream] {
  if self.closed {
    raise @http1.Http1Error::UnexpectedEof("client connection is closed")
  }
  if self.busy {
    raise @http1.Http1Error::InvalidFraming(
      "previous response body has not been consumed",
    )
  }
  let framing = match request.body.size_hint().exact_size() {
    Some(size) => @http1.BodyFraming::ContentLength(size)
    None =>
      if request.version == Http11 {
        Chunked
      } else {
        raise @http1.Http1Error::InvalidFraming(
          "HTTP/1.0 requests require an exact body size",
        )
      }
  }
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
  let mut remaining : Int? = match framing {
    ContentLength(size) => Some(size)
    _ => None
  }
  let mut sent_trailers = false
  while request.body.next_frame() is Some(frame) {
    match frame {
      Data(data) => {
        if sent_trailers {
          raise @http1.Http1Error::InvalidFraming("body data follows trailers")
        }
        match remaining {
          Some(value) => {
            if data.length() > value {
              raise @http1.Http1Error::InvalidFraming(
                "request body exceeds content-length",
              )
            }
            remaining = Some(value - data.length())
          }
          None => ()
        }
        let encoded = match @http1.encode_body_data(data, framing) {
          Ok(value) => value
          Err(error) => raise error
        }
        write_with_timeout(self.writer, encoded, self.write_timeout_ms)
      }
      Trailers(trailers) => {
        if sent_trailers {
          raise @http1.Http1Error::InvalidFraming("duplicate body trailers")
        }
        sent_trailers = true
        let encoded = match @http1.encode_body_end(framing, trailers~) {
          Ok(value) => value
          Err(error) => raise error
        }
        write_with_timeout(self.writer, encoded, self.write_timeout_ms)
      }
    }
  }
  if remaining is Some(value) && value != 0 {
    raise @http1.Http1Error::InvalidFraming(
      "request body shorter than content-length",
    )
  }
  if framing == Chunked && !sent_trailers {
    write_with_timeout(
      self.writer,
      @http1.encode_body_end(framing).unwrap(),
      self.write_timeout_ms,
    )
  }
  let decoder = @http1.ResponseDecoder::new(
    request.http_method,
    limits=self.limits,
  )
  for ;; {
    match decoder.next() {
      Err(error) => raise error
      Ok(Some(ResponseHead(value))) =>
        if value.status >= 100 && value.status < 200 && value.status != 101 {
          ()
        } else {
          if header_has_token(value.headers, "connection", "close") {
            self.closed = true
          }
          self.busy = true
          let stream = @body.BodyStream::from_pull(async fn() {
            for ;; {
              match decoder.next() {
                Err(error) => {
                  self.busy = false
                  raise error
                }
                Ok(Some(ResponseData(data))) => return Some(Data(data))
                Ok(Some(ResponseTrailers(value))) =>
                  return Some(Trailers(value))
                Ok(Some(ResponseEnd)) => {
                  self.busy = false
                  return None
                }
                Ok(Some(ResponseHead(_))) => ()
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
                        Err(error) => {
                          self.busy = false
                          raise error
                        }
                      }
                    None => {
                      self.closed = true
                      decoder.finish_input()
                    }
                  }
              }
            }
          })
          return value.map_body(fn(_) { stream })
        }
      Ok(Some(ResponseData(_))) | Ok(Some(ResponseTrailers(_))) =>
        raise @http1.Http1Error::InvalidFraming(
          "response body event arrived before final response head",
        )
      Ok(Some(ResponseEnd)) =>
        raise @http1.Http1Error::InvalidFraming(
          "response ended before final response head",
        )
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
