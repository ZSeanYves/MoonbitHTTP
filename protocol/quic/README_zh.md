# `protocol/quic`

[English](README.md) · [项目说明](../../README_zh.md)

提供 QUIC v1 包和帧编解码、CRYPTO 与 STREAM 重组、流量控制、丢包恢复和连接 ID 管理。示例补齐一段乱序到达的 CRYPTO 数据。驱动连接时向 `poll(now_ms)` 传入时间戳并发送产出的数据报。使用 `send_stream_prefix` 按可用额度写入，并在确认 STREAM 帧时通知发送端释放重传状态，包括只含 FIN 的空帧。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/protocol/quic",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "reassemble out-of-order CRYPTO data" {
  let crypto = @quic.QuicCryptoReassembler::new().unwrap()
  assert_eq(crypto.feed(3L, b"lo").unwrap(), [])
  let _ = crypto.feed(0L, b"hel").unwrap()
  assert_eq(crypto.next_offset(), 5L)
}
```

## 流量控制与恢复

应用每消费一段字节，调用一次 `consume_stream_data(stream_id, count)`。自定义传输需要可靠发送 `take_credit_updates()` 返回的帧，并在确认送达后调用 `acknowledge_stream_frame(frame)`。部分写入时保留尚未发送的后缀。放弃读取时调用 `stop_sending`，收到对端的 `SendStopped` 后丢弃该流待发送的数据。[连接 ID 支持范围](CID-SUPPORT.md)
