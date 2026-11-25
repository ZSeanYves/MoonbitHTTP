# `policy/content_coding`

[中文](README_zh.md) · [Project README](../../README.md)

Decode response bodies with `identity`, `gzip`, `deflate` or `br` content codings. Use `decode_bytes_response` for a buffered body or `decode_response` for a streaming body. Stacked codings are removed in reverse order. `ContentCodingLimits` bounds input, decoded output and the number of layers.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/policy/content_coding",
  "ZSeanYves/http/core/types",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "decode a deflate response" {
  let headers = @types.HeaderMap::new()
  headers.append_string("content-encoding", "deflate").unwrap()
  let response : @types.Response[Bytes] = {
    status: 200,
    version: Http11,
    headers,
    body: b"\x78\x9c\xcb\x48\xcd\xc9\xc9\x07\x00\x06\x2c\x02\x15",
  }
  let decoded = @content_coding.decode_bytes_response(response).unwrap()
  assert_eq(decoded.body, b"hello")
  assert_true(decoded.headers.get_string("content-encoding") is None)
}
```

## Migrating from decoder fields

Replace reads of `decoder.encoded_bytes`, `decoder.decoded_bytes` and `decoder.finished` with the methods below. Keep the coding and limits passed to `new` if you need to report them.

```moonbit
test "read decoder progress" {
  let decoder = @content_coding.ContentDecoder::new(Identity).unwrap()
  let step = decoder.step(b"hello", end=true).unwrap()
  assert_eq(step.output, b"hello")
  assert_eq(decoder.encoded_bytes(), 5)
  assert_eq(decoder.decoded_bytes(), 5)
  assert_true(decoder.is_finished())
}
```

For stacked codings, the `ContentDecoderChain` queues and their indices are now private. Call `poll()` to get the next action. On `ContentDecodeNeedInput`, call `feed` with the next fragment, using `end=true` on the last one. Consume each `ContentDecoded(bytes)` and poll again. Stop on `ContentDecodeDone` or handle the returned error.

`DecoderBackend` and `BrotliSink` are now package-private. Select the encoding with `ContentCoding` at construction. For a streaming response from `decode_response`, use `response.body.next_frame()` to read data and trailers, or `response.body.cancel(reason)` to stop early.
