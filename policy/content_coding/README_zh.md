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
