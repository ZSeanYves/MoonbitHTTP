# `internal/packet_crypto`

[English](README.md) · [项目说明](../../README_zh.md)

QUIC 包保护使用的底层密码学函数，涵盖 HKDF、AEAD 和首部保护。Native 加载 OpenSSL 3.x，Wasm、Wasm-GC 和 JavaScript 使用实验性的 `mizchi/experimental_crypto` 后端。派生 QUIC 包密钥和处理握手消息时可使用[协议 TLS 包](../../protocol/tls/README_zh.md)。
