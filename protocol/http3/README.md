# `protocol/http3`

[中文](README_zh.md) · [Project README](../../README.md)

Decode HTTP/3 frames and QPACK field sections, or drive request and control streams together with `Http3Session`. The example decodes a single DATA frame from a request stream. For a live connection, `advance` drives QUIC and HTTP/3. Handle stream resets and GOAWAY in the connection loop.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/protocol/http3",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "decode a DATA frame" {
  let decoder = @http3.Http3FrameDecoder::new().unwrap()
  decoder.feed(b"\x00\x02hi").unwrap()
  assert_true(decoder.next() is Ok(Some(H3Data(b"hi"))))
  decoder.finish().unwrap()
}
```

## Driving a session

Give one session exclusive access to the QUIC application streams. Feed TLS driver actions from `start`, `on_datagram` and `poll` to `advance`. Transmit its datagrams even when the batch includes a failure. After queuing writes, call `advance([], now_ms)`. Retry `Http3WriteBlocked` after transport progress.

The standalone decoder returns whole frames. A session can emit several data events for one frame. For a pull-based consumer, call `defer_body_credit` and then `consume_body` as bytes are read or discarded. Dispatch completion on `H3MessageFinished`, which may arrive after FIN if QPACK is blocked. A server starts graceful shutdown with `send_goaway(first_rejected)`. Admitted requests below the boundary can finish.
