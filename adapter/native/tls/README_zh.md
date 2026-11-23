# `adapter/native/tls`

Status: canonical
Scope: public Native OpenSSL TLS and QUIC-TLS adapter
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
使用 OpenSSL 实现 TlsProvider 与 QuicTlsProvider，通过注入 connection 传递 TLS record/QUIC CRYPTO，不做 DNS 或 socket。

`NativeEntropy` 用 OpenSSL `RAND_bytes` 填充调用方的字节缓冲区。原生 HTTP/3 客户端用它生成初始目的连接 ID 和本地连接 ID。

## 入口
入口是 NativeTlsProvider::new、NativeQuicTlsProvider::new，显式传入 CA、PEM 凭据、identity 和 ALPN。

## 依赖与目标
依赖 transport 与 Native OpenSSL FFI，仅支持 native；普通 TLS 需要 OpenSSL 3，QUIC TLS 需要 3.5+。

## 使用边界
将 provider 注入 application/client、adapter/native/server、QuicTlsDriver；h3 ALPN 是 QUIC 设置，不会把 TCP 变成 QUIC。

应用完成最后一次写入后，调用 `SecureConnection::finish` 发送 `close_notify` 并释放流。该调用在本端发送完成后返回。调用 `close` 可立即释放连接。对端 TCP 在发送 TLS 关闭通知前断开时，读取将返回错误。

## 不变量与范围
完成前检查证书链、有效期、SAN、key、TLS version、ALPN；0-RTT 关闭。Native TLS 可通过 `TlsOptions.revocation_lists` 注入 PEM CRL，设置 `require_crl` 后缺少或无效 CRL 会硬失败，并检查完整验证链。客户端设置 `require_ocsp` 后必须收到并验证 DER stapled OCSP；服务端通过 `ocsp_response` 提供该响应。OCSP 只验证显式 stapled response，不会在线访问 responder，也不会做 DNS/socket；Wasm 没有 native 撤销提供器。

## 规范文档
- [中文总览](../../../README_zh.md)
