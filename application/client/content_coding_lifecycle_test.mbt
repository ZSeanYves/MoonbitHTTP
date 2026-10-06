///|
async test "pooled content decoding: codec EOF releases lease and preserves reuse" {
  let payload = b"pooled compressed response"
  let cases = [
    ("deflate", @zlib.zlib_compress(payload)),
    ("br", Bytes::from_array(@fbr.brotli_sync(payload.to_fixedarray()))),
  ]
  for entry in cases {
    let (coding, compressed) = entry
    let mut connects = 0
    let mut cursor = 0
    let chunks = [
      @utf8.encode(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Encoding: \{coding}\r\n\r\n\{compressed.length().to_string(radix=16)}\r\n",
      ) +
      compressed +
      b"\r\n",
      b"0\r\nx-finished: yes\r\n\r\n",
      b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    ]
    let executor = @client.Http1PooledRoundTripper::new(
      (endpoint, _) => {
        connects += 1
        Ok(
          @transport.StreamConnection::new(
            endpoint,
            fn(_) {
              if cursor == chunks.length() {
                Ok(None)
              } else {
                let chunk = chunks[cursor]
                cursor += 1
                Ok(Some(chunk))
              }
            },
            fn(_) { Ok(()) },
            fn() { () },
          ),
        )
      },
      fn(_, _) { Err(Unsupported) },
      resolve=Some(test_resolve_origin),
      pool_limits={ max_total: 1, max_idle: 1, },
      authorize=fn(_, _) { Ok(()) },
      now_millis=fn() { 0L },
    ).unwrap()
    defer executor.close()
    let request = pooled_request("http://origin.test/", @types.HeaderMap::new())
    @async.with_timeout(1000, async fn() {
      let first = executor.execute_stream(request).unwrap()
      let decoded = @content_coding.decode_response(first).unwrap()
      let (bytes, trailers) = @body.collect(decoded.body)
      assert_eq(bytes, payload)
      assert_eq(
        trailers.unwrap().get_string("x-finished").unwrap().to_string_lossy(),
        "yes",
      )
      assert_eq(executor.execute(request).unwrap().body, b"ok")
    })
    assert_eq(connects, 1)
    assert_eq(cursor, 3)
  }
}
