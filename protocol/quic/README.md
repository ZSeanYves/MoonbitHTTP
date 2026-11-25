# `protocol/quic`

[中文](README_zh.md) · [Project README](../../README.md)

QUIC v1 packet and frame codecs, CRYPTO and STREAM reassembly, flow control, loss recovery and connection IDs. The example fills a gap in the CRYPTO stream. When driving a connection, pass a timestamp to `poll(now_ms)` and send the resulting datagrams. Use `send_stream_prefix` for flow-controlled partial writes and report acknowledged STREAM frames, including empty FINs, to release retransmission state.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/protocol/quic",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "reassemble out-of-order CRYPTO data" {
  let crypto = @quic.QuicCryptoReassembler::new().unwrap()
  assert_eq(crypto.feed(3L, b"lo").unwrap(), [])
  let _ = crypto.feed(0L, b"hel").unwrap()
  assert_eq(crypto.next_offset(), 5L)
}
```

## Flow control and recovery

Call `consume_stream_data(stream_id, count)` once for bytes accepted by the application. A custom transport must send the frames returned by `take_credit_updates()` reliably and call `acknowledge_stream_frame(frame)` on delivery. Keep the unwritten suffix after a partial write. Use `stop_sending` to abandon input. When the peer sends `SendStopped`, discard queued output for that stream. [Connection ID support](CID-SUPPORT.md)
