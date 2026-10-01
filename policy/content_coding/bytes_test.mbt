///|
async test "content coding bytes response: decodes and removes representation metadata" {
  let original = b"bounded byte response"
  let encoded = @gzip.gzip_compress(original)
  let headers = @types.HeaderMap::new()
  headers.append_string("content-encoding", "gzip").unwrap()
  headers.append_string("content-length", encoded.length().to_string()).unwrap()
  let response : @types.Response[Bytes] = {
    status: 200,
    version: Http11,
    headers,
    body: encoded,
  }
  let decoded = @content_coding.decode_bytes_response(response, limits={
    max_encoded_bytes: 4096,
    max_decoded_bytes: 4096,
    max_codings: 4,
    output_chunk_bytes: 1024,
  }).unwrap()
  assert_eq(decoded.body, original)
  assert_true(decoded.headers.get_string("content-encoding") is None)
  assert_true(decoded.headers.get_string("content-length") is None)
}

///|
async test "content coding bytes response: decoded limit is enforced" {
  let original = FixedArray::make(1024, b'a').unsafe_reinterpret_as_bytes()
  let encoded = @gzip.gzip_compress(original)
  let headers = @types.HeaderMap::new()
  headers.append_string("content-encoding", "gzip").unwrap()
  let response : @types.Response[Bytes] = {
    status: 200,
    version: Http11,
    headers,
    body: encoded,
  }
  assert_true(
    @content_coding.decode_bytes_response(response, limits={
      max_encoded_bytes: 4096,
      max_decoded_bytes: 32,
      max_codings: 4,
      output_chunk_bytes: 128,
    })
    is Err(DecodedBodyLimitExceeded(32)),
  )
}
