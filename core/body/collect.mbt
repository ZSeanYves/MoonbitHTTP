///|
pub(all) suberror BodyLimitExceeded {
  BodyLimitExceeded(limit~ : Int)
} derive(Debug, Eq)

///|
pub async fn[B : Body] collect(
  body : B,
  max_bytes? : Int = 16 * 1024 * 1024,
) -> (Bytes, @types.HeaderMap?) {
  let mut cause : Error = BodyError::Cancelled
  errdefer body.cancel(cause)
  let result : Result[(Bytes, @types.HeaderMap?), Error] = try {
    if max_bytes < 0 {
      raise BodyError::InvalidLimit(max_bytes)
    }
    let data = @buffer.Buffer()
    let mut trailers : @types.HeaderMap? = None
    while body.next_frame() is Some(frame) {
      match validate_frame(frame, trailers is Some(_)) {
        Err(error) => raise error
        Ok(SkipFrame) => continue
        Ok(DeliverFrame(_)) => ()
      }
      match frame {
        Data(chunk) => {
          if chunk.length() > max_bytes - data.length() {
            raise BodyLimitExceeded(limit=max_bytes)
          }
          data.write_bytes(chunk)
        }
        Trailers(value) => trailers = Some(value)
      }
    }
    Ok((data.to_bytes(), trailers))
  } catch {
    error => Err(error)
  }
  match result {
    Ok(value) => value
    Err(error) => {
      cause = error
      raise error
    }
  }
}
