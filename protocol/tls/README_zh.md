# `protocol/tls`

[English](README.md) · [项目说明](../../README_zh.md)

重组 QUIC CRYPTO 帧承载的 TLS 握手消息，并派生包保护密钥。Native 的包保护使用 OpenSSL 3.x，Wasm、Wasm-GC 和 JavaScript 使用 `mizchi/experimental_crypto`。完成握手及对端认证需要接入 `runtime/transport` 定义的 `QuicTlsProvider`。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/protocol/tls",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "read a fragmented handshake message" {
  let decoder = @tls.QuicHandshakeDecoder::new(QuicHandshake).unwrap()
  assert_eq(decoder.feed(0L, b"\x08\x00").unwrap(), [])
  let messages = decoder.feed(2L, b"\x00\x02ab").unwrap()
  assert_eq(messages[0].message_type, 8)
  decoder.finish().unwrap()
}
```
