# `protocol/http3`

[English](README.md) · [项目说明](../../README_zh.md)

可单独解析 HTTP/3 帧和 QPACK 字段区段，也可用 `Http3Session` 同时驱动请求流与控制流。示例从请求流解析一个 DATA 帧。实际连接通过 `advance` 推进 QUIC 和 HTTP/3，并在连接循环中处理流重置和 GOAWAY。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/protocol/http3",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "decode a DATA frame" {
  let decoder = @http3.Http3FrameDecoder::new().unwrap()
  decoder.feed(b"\x00\x02hi").unwrap()
  assert_true(decoder.next() is Ok(Some(H3Data(b"hi"))))
  decoder.finish().unwrap()
}
```

## 驱动会话

一个会话独占 QUIC 应用流。将 TLS 驱动在 `start`、`on_datagram` 和 `poll` 中返回的动作交给 `advance`。即使同批动作包含失败，也要发送其中的数据报。应用排入写操作后调用 `advance([], now_ms)`；遇到 `Http3WriteBlocked` 时，等传输层取得进展后重试。

独立解码器返回完整帧，会话则可能为一个帧产生多次数据事件。按需读取正文时先用 `defer_body_credit`，再按实际读取或丢弃的字节数调用 `consume_body`。以 `H3MessageFinished` 判定消息完成，QPACK 阻塞时该事件可能晚于 FIN。服务端可用 `send_goaway(first_rejected)` 开始排空，边界以下已接收的请求可继续完成。

## 迁移到 0.9 的驱动诊断接口

通过 `driver.blocked_bytes()` 和 `driver.blocked_stream_count()` 查询等待解码的数据量及流数。连接、失败原因、本地控制流和 QPACK 流 ID 可通过已有同名方法读取。公开接口已移除 `decoders`、`kinds`、`prefixes`、`blocked_frames` 和 `pending_fin`。在 `QpackDecoder` 上使用 `capacity()`、`table_size()`、`total_inserts()` 和 `blocked_stream_count()`。调用者可保留构造时的配置，并从流操作的返回值读取错误。表 `blocked` 和队列 `encoder_buffer` 已私有化。
