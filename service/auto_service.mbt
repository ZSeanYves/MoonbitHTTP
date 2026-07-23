///|
async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_auto_connection_inner(
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
  match detection {
    Detected(Http2PriorKnowledge) =>
      serve_http2_connection(
        replay,
        writer,
        service,
        config=config.without_close_callback(),
      )
    Detected(Http1) =>
      serve_http1_or_h2c_connection(
        replay,
        writer,
        service,
        config=config.without_close_callback(),
      )
    Detected(Http2Upgrade) =>
      serve_http1_or_h2c_connection(
        replay,
        writer,
        service,
        config=config.without_close_callback(),
      )
    Undetermined =>
      raise @http1.Http1Error::InvalidStartLine(
        "protocol detection did not finish",
      )
  }
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_auto_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  serve_auto_connection_inner(
    reader,
    writer,
    service,
    config=config.without_close_callback(),
  ) catch {
    error => {
      if config.close_callback is Some(callback) {
        callback(Some(error))
      }
      raise error
    }
  }
  if config.close_callback is Some(callback) {
    callback(None)
  }
}
