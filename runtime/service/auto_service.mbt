///|
async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_auto_connection_inner(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config~ : ServerConfig = ServerConfig::defaults(),
  shutdown~ : ServerShutdown? = None,
) -> Unit {
  let detector = @detection.Detector::new()
  let mut checked = 0
  let detection = for ;; {
    let prefix = read_before_shutdown(shutdown, async fn() {
      io_with_timeout(config.read_timeout_ms, async fn() {
        Some(reader.peek_at_least(checked + 1)) catch {
          UnexpectedEof => None
          error => raise error
        }
      })
    })
    guard prefix is Some(prefix) else {
      if shutdown is Some(signal) && signal.has_started() {
        return
      }
      break @detection.Detected(Http1)
    }
    let end = prefix.length().min(24)
    let decision = detector.feed(prefix[checked:end])
    if decision != Undetermined {
      break decision
    }
    checked = end
  }
  match detection {
    Detected(Http2PriorKnowledge) =>
      serve_http2_connection(
        reader,
        writer,
        service,
        config=config.without_close_callback(),
        shutdown~,
      )
    Detected(Http1 | Http2Upgrade) =>
      serve_http1_or_h2c_connection(
        reader,
        writer,
        service,
        config=config.without_close_callback(),
        shutdown~,
      )
    Undetermined =>
      raise @http1.Http1Error::InvalidStartLine(
        "protocol detection did not finish",
      )
  }
}

///|
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_auto_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config~ : ServerConfig = ServerConfig::defaults(),
  shutdown~ : ServerShutdown? = None,
) -> Unit {
  run_connection_scope(
    () => {
      serve_auto_connection_inner(
        reader,
        writer,
        service,
        config=config.without_close_callback(),
        shutdown~,
      )
    },
    config.close_callback,
  )
}
