///|
/// Resolve a declared wire length against the producer's hint before HEADERS.
fn h2_outgoing_length(
  stream_id : Int32,
  headers : @types.HeaderMap,
  hint : Int32?,
) -> Int32? raise @http2.H2ProtocolError {
  let declared = match headers.content_length() {
    Ok(value) => value
    Err(_) =>
      raise StreamError(stream_id, ProtocolError, "invalid content-length")
  }
  if declared is Some(length) && hint is Some(size) && size != length {
    raise StreamError(
      stream_id,
      ProtocolError,
      "body size disagrees with content-length",
    )
  }
  match declared {
    Some(_) => declared
    None => hint
  }
}

///|
/// Both roles apply the same length and trailer rules. Each connection owns
/// its flow-control waiter, header compression context and serialized writer.
async fn write_h2_body(
  stream_id : Int32,
  read : async () -> @body.Frame?,
  expected : Int32?,
  end_on_headers : Bool,
  write_chunk : async (BytesView) -> Int32,
  write_end : async (Bytes) -> Unit,
  write_trailers : async (@types.HeaderMap) -> Unit,
) -> Unit {
  let mut remaining = expected
  let mut ended = end_on_headers
  while read() is Some(frame) {
    match frame {
      _ if ended =>
        raise @http2.H2ProtocolError::StreamError(
          stream_id,
          ProtocolError,
          "body frame after end of stream",
        )
      Data(data) => {
        if remaining is Some(left) {
          if data.length() > left {
            raise @http2.H2ProtocolError::StreamError(
              stream_id,
              ProtocolError,
              "body exceeds declared length",
            )
          }
          remaining = Some(left - data.length())
        }
        let mut offset = 0
        while offset < data.length() {
          let length = (data.length() - offset).min(
            @http2.H2_DEFAULT_MAX_FRAME_SIZE,
          )
          offset += write_chunk(data[offset:offset + length])
        }
      }
      Trailers(trailers) => {
        if remaining is Some(left) && left != 0 {
          raise @http2.H2ProtocolError::StreamError(
            stream_id,
            ProtocolError,
            "trailers before declared body length",
          )
        }
        write_trailers(trailers)
        ended = true
      }
    }
  }
  if remaining is Some(left) && left != 0 {
    raise @http2.H2ProtocolError::StreamError(
      stream_id,
      ProtocolError,
      "body ended before declared length",
    )
  }
  if !ended {
    write_end(@http2.encode_data_frames(stream_id, b"", true).unwrap_or_error())
  }
}

///|
/// Reserve flow credit under the writer lock. A stream cancelled in the
/// writer queue has not consumed credit for bytes it never sent.
async fn write_h2_data_chunk(
  stream_id : Int32,
  chunk : BytesView,
  lock : @async.Mutex,
  reserve : async (Int32) -> Int32,
  wait : async () -> Unit,
  write : async (Bytes) -> Unit,
) -> Int32 {
  for ;; {
    let capacity = {
      lock.acquire()
      defer lock.release()
      let capacity = reserve(chunk.length())
      if capacity > 0 {
        write(
          @http2.encode_data_frames(
            stream_id,
            chunk[:capacity].to_owned(),
            false,
          ).unwrap_or_error(),
        )
      }
      capacity
    }
    if capacity > 0 {
      return capacity
    }
    wait()
  }
}
