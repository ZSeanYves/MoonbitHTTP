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
async fn[B : @body.Body] write_h2_body(
  stream_id : Int32,
  body : B,
  expected : Int32?,
  end_on_headers : Bool,
  reserve : async (Int32) -> Int32,
  write_bytes : async (Bytes) -> Unit,
  write_trailers : async (@types.HeaderMap) -> Unit,
) -> Unit {
  let mut remaining = expected
  let mut ended = end_on_headers
  while body.next_frame() is Some(frame) {
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
          let capacity = reserve(
            (data.length() - offset).min(@http2.H2_DEFAULT_MAX_FRAME_SIZE),
          )
          let chunk = data[offset:offset + capacity].to_owned()
          write_bytes(
            @http2.encode_data_frames(stream_id, chunk, false).unwrap_or_error(),
          )
          offset += capacity
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
    write_bytes(
      @http2.encode_data_frames(stream_id, b"", true).unwrap_or_error(),
    )
  }
}
