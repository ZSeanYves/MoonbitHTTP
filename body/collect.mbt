///|
pub(all) suberror BodyLimitExceeded {
  BodyLimitExceeded(limit~ : Int)
} derive(Debug, Eq)

///|
pub async fn[B : Body] collect(
  body : B,
  max_bytes? : Int = 16 * 1024 * 1024,
) -> (Bytes, @types.HeaderMap?) {
  if max_bytes < 0 {
    let error = BodyError::InvalidLimit(max_bytes)
    body.cancel(error)
    raise error
  }
  let data : Array[Byte] = []
  let mut trailers : @types.HeaderMap? = None
  let mut trailers_seen = false
  errdefer body.cancel(BodyError::Cancelled)
  while true {
    let outcome : Result[Frame?, Error] = Ok(body.next_frame()) catch {
      error => Err(error)
    }
    let next = match outcome {
      Ok(value) => value
      Err(error) => {
        body.cancel(error)
        raise error
      }
    }
    guard next is Some(frame) else { break }
    match validate_frame(frame, trailers_seen) {
      Err(error) => {
        body.cancel(error)
        raise error
      }
      Ok(SkipFrame) => ()
      Ok(DeliverFrame(next_trailers_seen)) => {
        trailers_seen = next_trailers_seen
        match frame {
          Data(chunk) => {
            if chunk.length() > max_bytes - data.length() {
              let error = BodyLimitExceeded(limit=max_bytes)
              body.cancel(error)
              raise error
            }
            for byte in chunk {
              data.push(byte)
            }
          }
          Trailers(value) => trailers = Some(value)
        }
      }
    }
  }
  (Bytes::from_array(data), trailers)
}
