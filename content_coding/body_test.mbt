///|
struct ContentTrackingBody {
  frames : Array[@body.Frame]
  mut cursor : Int
  mut cancel_count : Int
}

///|
impl @body.Body for ContentTrackingBody with fn next_frame(self) {
  if self.cursor == self.frames.length() {
    None
  } else {
    let result = self.frames[self.cursor]
    self.cursor += 1
    Some(result)
  }
}

///|
impl @body.Body for ContentTrackingBody with fn size_hint(_self) {
  @body.SizeHint::unknown()
}

///|
impl @body.Body for ContentTrackingBody with fn cancel(self, _error) {
  self.cancel_count += 1
}

///|
async test "content coding body: streams decoded data before trailers" {
  let original = b"decoded data remains a streaming body"
  let compressed = @gzip.gzip_compress(original)
  let trailers = @types.HeaderMap::new()
  trailers.append_string("x-checksum", "ok").unwrap()
  let source = @body.QueueBody::new([
    Data(compressed[:2].to_owned()),
    Data(compressed[2:9].to_owned()),
    Data(compressed[9:].to_owned()),
    Trailers(trailers),
  ])
  let decoded = @content_coding.DecodedBody::new(
    source,
    [Gzip],
    limits=content_test_limits(4096, 4096),
  ).unwrap()
  assert_eq(decoded.size_hint().lower_bound(), 0)
  assert_true(decoded.size_hint().upper_bound() is None)
  let (data, result_trailers) = @body.collect(decoded, max_bytes=4096)
  assert_eq(data, original)
  assert_eq(
    result_trailers.unwrap().get_string("x-checksum").unwrap().to_string_lossy(),
    "ok",
  )
}

///|
async test "content coding response: removes metadata for the encoded representation" {
  let original = b"representation metadata"
  let compressed = @zlib.zlib_compress(original)
  let headers = @types.HeaderMap::new()
  headers.append_string("content-encoding", "deflate").unwrap()
  headers
  .append_string("content-length", compressed.length().to_string())
  .unwrap()
  headers.append_string("content-type", "text/plain").unwrap()
  let response : @types.Response[@body.FullBody] = {
    status: 200,
    version: Http11,
    headers,
    body: @body.FullBody::new(compressed),
  }
  let decoded = @content_coding.decode_response(
    response,
    limits=content_test_limits(4096, 4096),
  ).unwrap()
  assert_true(decoded.headers.get_string("content-encoding") is None)
  assert_true(decoded.headers.get_string("content-length") is None)
  assert_eq(
    decoded.headers.get_string("content-type").unwrap().to_string_lossy(),
    "text/plain",
  )
  let (body, _) = @body.collect(decoded.body, max_bytes=4096)
  assert_eq(body, original)
}

///|
async test "content coding body: a decompression limit cancels its upstream once" {
  let original = FixedArray::make(4096, b'a').unsafe_reinterpret_as_bytes()
  let compressed = @gzip.gzip_compress(original)
  let source : ContentTrackingBody = {
    frames: [Data(compressed)],
    cursor: 0,
    cancel_count: 0,
  }
  let decoded = @content_coding.DecodedBody::new(
    source,
    [Gzip],
    limits=content_test_limits(4096, 64),
  ).unwrap()
  try @body.collect(decoded, max_bytes=4096) catch {
    @content_coding.ContentCodingError::DecodedBodyLimitExceeded(64) => ()
    _ => fail("decoded body limit error changed")
  } noraise {
    _ => fail("compressed bomb was accepted")
  }
  assert_eq(source.cancel_count, 1)
}

///|
async test "content coding body: malformed finalization preserves its typed error" {
  let source : ContentTrackingBody = {
    frames: [Data(b"short")],
    cursor: 0,
    cancel_count: 0,
  }
  let decoded = @content_coding.DecodedBody::new(
    source,
    [Gzip],
    limits=content_test_limits(4096, 4096),
  ).unwrap()
  try decoded.next_frame() catch {
    @content_coding.ContentCodingError::TruncatedEncodedBody(Gzip) => ()
    _ => fail("truncated coding error changed")
  } noraise {
    _ => fail("truncated encoded body was accepted")
  }
  try decoded.next_frame() catch {
    @content_coding.ContentCodingError::TruncatedEncodedBody(Gzip) => ()
    _ => fail("terminal coding error was not stable")
  } noraise {
    _ => fail("terminal coding failure became EOF")
  }
  assert_eq(source.cancel_count, 1)
}
