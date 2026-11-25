# `protocol/http2`

[中文](README_zh.md) · [Project README](../../README.md)

Decode and encode HTTP/2 frames and HPACK header blocks, and track multiplexed streams and flow control with `H2Connection`. Use separate HPACK contexts for each direction and keep each context for the life of the connection. The peer decodes blocks in the order they were encoded.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/protocol/http2",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "exchange an HPACK header block" {
  let sender = @http2.HpackContext::new()
  let receiver = @http2.HpackContext::new()
  let fields : Array[@http2.HpackHeader] = [{ name: "x-id", value: b"42", }]
  let block = sender.encode_incremental(fields).unwrap()
  assert_eq(receiver.decode(block).unwrap(), fields)
}
```
