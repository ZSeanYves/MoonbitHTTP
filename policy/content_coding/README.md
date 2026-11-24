# `policy/content_coding`

[中文](README_zh.md) · [Project README](../../README.md)

Decode response bodies with `identity`, `gzip`, `deflate` or `br` content codings. Use `decode_bytes_response` for a buffered body or `decode_response` for a streaming body. Stacked codings are removed in reverse order. `ContentCodingLimits` bounds input, decoded output and the number of layers.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/policy/content_coding",
  "ZSeanYves/MoonbitHTTP/core/types",
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
