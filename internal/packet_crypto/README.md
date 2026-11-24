# `internal/packet_crypto`

[中文](README_zh.md) · [Project README](../../README.md)

Cryptographic primitives used by QUIC packet protection, including HKDF, AEAD and header protection. The Native implementation loads OpenSSL 3.x. Wasm, Wasm-GC and JavaScript use `mizchi/experimental_crypto`. For QUIC packet keys and handshake framing, use the [protocol TLS package](../../protocol/tls/README.md).
