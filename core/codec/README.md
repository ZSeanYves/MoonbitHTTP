# `core/codec`

[中文](README_zh.md) · [Project README](../../README.md)

Use the bounded byte buffer for incremental input and the shared Huffman codec for HPACK and QPACK string literals. The buffer reports incomplete input and enforces configured size limits.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/core/codec",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "round-trip a Huffman string" {
  let encoded = @codec.huffman_encode(b"www.example.com")
  assert_eq(@codec.huffman_decode(encoded).unwrap(), b"www.example.com")
}
```
