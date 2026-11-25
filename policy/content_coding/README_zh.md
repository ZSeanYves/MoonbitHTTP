# `policy/content_coding`

[English](README.md) · [项目说明](../../README_zh.md)

解码采用 `identity`、`gzip`、`deflate` 或 `br` 的响应正文。完整字节响应使用 `decode_bytes_response`，流式响应使用 `decode_response`。多层编码按相反顺序解开；可通过 `ContentCodingLimits` 限制输入、输出和编码层数。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/policy/content_coding",
  "ZSeanYves/http/core/types",
} for "test"
```

将示例保存为 `example_test.mbt`。

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

## 从解码器字段迁移

原先读取 `decoder.encoded_bytes`、`decoder.decoded_bytes` 和 `decoder.finished` 的地方改用下面三个方法。需要展示编码或限制时，可保留传给 `new` 的参数。

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

处理多层编码时，`ContentDecoderChain` 的队列和索引已改为包内字段。调用 `poll()` 获取下一步。收到 `ContentDecodeNeedInput` 时用 `feed` 提交下一段输入，最后一段传 `end=true`。收到 `ContentDecoded(bytes)` 时消费这段输出并继续轮询，收到 `ContentDecodeDone` 时结束，发生错误时处理返回的错误值。

`DecoderBackend` 和 `BrotliSink` 已从公开接口移除。构造时通过 `ContentCoding` 选择编码。对 `decode_response` 返回的流式响应，用 `response.body.next_frame()` 读取数据帧和尾部字段，提前停止时调用 `response.body.cancel(reason)`。
