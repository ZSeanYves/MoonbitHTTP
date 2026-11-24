# `protocol/http1`

[中文](README_zh.md) · [Project README](../../README.md)

Incrementally decode and encode HTTP/1.1 messages on a byte stream. Feed received bytes to a request or response decoder, then call `next()` until it returns `Ok(None)`. Handle headers, body data, trailers and message end separately. Call `finish_input()` at transport EOF so truncated messages are reported.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/protocol/http1",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "read headers across two chunks" {
  let decoder = @http1.RequestDecoder::new()
  decoder.feed(b"GET / HTTP/1.1\r\n").unwrap()
  assert_true(decoder.next() is Ok(None))
  decoder.feed(b"Host: example.com\r\n\r\n").unwrap()
  assert_true(decoder.next() is Ok(Some(RequestHead(_))))
  assert_true(decoder.next() is Ok(Some(RequestEnd)))
}
```
