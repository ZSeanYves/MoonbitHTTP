# `protocol/http1`

[English](README.md) · [项目说明](../../README_zh.md)

在字节流上增量解析和编码 HTTP/1.1 消息。向请求或响应解码器送入已收到的字节，反复调用 `next()`，直至返回 `Ok(None)`。分别处理首部、正文数据、尾部字段和消息结束事件。底层流到达 EOF 时调用 `finish_input()` 检查消息是否完整。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/protocol/http1",
} for "test"
```

将示例保存为 `example_test.mbt`。

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
