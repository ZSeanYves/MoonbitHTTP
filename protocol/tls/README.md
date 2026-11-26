# `protocol/tls`

[中文](README_zh.md) · [Project README](../../README.md)

Reassemble TLS handshake messages carried by QUIC CRYPTO frames and derive packet protection keys. Native packet protection uses OpenSSL 3.x. Wasm, Wasm-GC and JavaScript use `mizchi/experimental_crypto`. To authenticate a peer and complete the handshake, supply a `QuicTlsProvider` from `runtime/transport`.

For a Native QUIC handshake with peer certificate verification, construct a `NativeQuicTlsProvider`. [OpenSSL adapter and trust configuration](../../adapter/native/tls/README.md)

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/protocol/tls",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "read a fragmented handshake message" {
  let decoder = @tls.QuicHandshakeDecoder::new(QuicHandshake).unwrap()
  assert_eq(decoder.feed(0L, b"\x08\x00").unwrap(), [])
  let messages = decoder.feed(2L, b"\x00\x02ab").unwrap()
  assert_eq(messages[0].message_type, 8)
  decoder.finish().unwrap()
}
```
