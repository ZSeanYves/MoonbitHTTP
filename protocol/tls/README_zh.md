# `tls`

Status: canonical
Scope: public portable QUIC/TLS protocol primitives
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
提供 QUIC CRYPTO 握手重组、initial/retry integrity 和 packet key derivation；Native OpenSSL provider 独立于此。

## 入口
入口是 QuicHandshakeDecoder、QuicPacketKeys、quic_v1_initial_keys、derive_quic_packet_keys 和 Retry integrity helper。

## 依赖与目标
通过 `internal/packet_crypto` 选择包保护后端。Native 加载 OpenSSL 3，Wasm、Wasm-GC、JS 使用实验性的可移植密码实现。Native HTTP/3 握手另需 OpenSSL 3.5 或更新版本。

## 使用边界
按 encryption level/offset 输入 CRYPTO 分片，在握手边界 finish，并在需要时显式选择 cipher suite。

## 不变量与范围
重组和 key 使用前检查上限与 encryption level；不是完整证书验证器或 Native provider。

## 规范文档
- [中文总览](../../README_zh.md)
