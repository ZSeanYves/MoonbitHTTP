# `core/codec`

[English](README.md) · [项目说明](../../README_zh.md)

按片段接收输入时可使用有容量限制的字节缓冲区。HPACK 和 QPACK 的字符串字面量共用此包的 Huffman 编解码器。缓冲区会区分输入不完整与超出大小限制。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/core/codec",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "round-trip a Huffman string" {
  let encoded = @codec.huffman_encode(b"www.example.com")
  assert_eq(@codec.huffman_decode(encoded).unwrap(), b"www.example.com")
}
```
