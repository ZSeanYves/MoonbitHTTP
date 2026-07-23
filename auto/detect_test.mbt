///|
test "auto: fragmented preface remains ordered" {
  let detector = Detector::new()
  assert_eq(detector.feed(b"PRI * HTTP/2.0\r\n"), Undetermined)
  assert_eq(
    detector.feed(b"\r\nSM\r\n\r\nextra"),
    Detected(Http2PriorKnowledge),
  )
  assert_eq(detector.buffered(), b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\nextra")
}

///|
test "auto: detects h2c only with all required fields" {
  let headers = @types.HeaderMap::new()
  assert_eq(
    headers.append_string("connection", "upgrade, HTTP2-Settings"),
    Ok(()),
  )
  assert_eq(headers.append_string("upgrade", "h2c"), Ok(()))
  assert_eq(headers.append_string("http2-settings", "AAMAAABkAAQAAP__"), Ok(()))
  assert_eq(detect_h2c_upgrade(headers), true)
}
