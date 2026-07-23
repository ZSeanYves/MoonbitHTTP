///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_auto_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  let detector = @auto.Detector::new()
  let prefix : Array[Byte] = []
  let mut detection = @auto.Detection::Undetermined
  while detection == Undetermined && prefix.length() < 24 {
    match
      read_some_with_timeout(
        reader,
        24 - prefix.length(),
        config.read_timeout_ms,
      ) {
      None => break
      Some(bytes) => {
        for byte in bytes {
          prefix.push(byte)
        }
        detection = detector.feed(bytes)
      }
    }
  }
  if detection == Undetermined {
    detection = Detected(Http1)
  }
  let replay = @aio.MemoryReader(async fn(replay_writer) {
    replay_writer.write(Bytes::from_array(prefix))
    replay_writer.write_reader(reader)
  })
  let read_timeout_ms = config.read_timeout_ms
  let write_timeout_ms = config.write_timeout_ms
  match detection {
    Detected(Http2PriorKnowledge) =>
      serve_http2_connection(
        replay,
        writer,
        service,
        limits=config.limits,
        read_timeout_ms?,
        write_timeout_ms?,
      )
    Detected(Http1) | Detected(Http2Upgrade) =>
      serve_http1_or_h2c_connection(replay, writer, service, config~)
    Undetermined =>
      raise @http1.Http1Error::InvalidStartLine(
        "protocol detection did not finish",
      )
  }
}
