# `protocol/http2`

[English](README.md) · [项目说明](../../README_zh.md)

提供 HTTP/2 帧和 HPACK 首部块编解码，`H2Connection` 跟踪多路复用的流和流量控制。两个传输方向分别维护 HPACK 上下文，每个上下文随连接复用。接收方按发送顺序解码首部块。

接收侧的 HPACK 表上限调小时，要等对端确认对应的 SETTINGS 才生效。跨字段块复用解码器，才能按此前的上限读取在途的字段块。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/protocol/http2",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "exchange an HPACK header block" {
  let sender = @http2.HpackContext::new()
  let receiver = @http2.HpackContext::new()
  let fields : Array[@http2.HpackHeader] = [{ name: "x-id", value: b"42", }]
  let block = sender.encode_incremental(fields).unwrap()
  assert_eq(receiver.decode(block).unwrap(), fields)
}
```
