# `quic`

Status: canonical
Scope: public QUIC packet, recovery, path, and driver
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
提供 QUIC packet/frame codec、connection/path state、transport parameters、丢包恢复、Retry/version、key phase 和 TLS/datagram driver。

## 入口
入口是 QuicDatagramDriver、QuicTlsDriver、QuicConnection、QuicRecovery、QuicTransportParameters、QuicRetryTokenManager。

## 依赖与目标
依赖 types、transport、portable tls，面向四目标协议核心。

## 使用边界
显式传入 role、endpoint、limits、clock、entropy、TLS；输入 datagram/timer 并执行 action。

## 不变量与范围
packet space、frame legality、amplification、路径验证、Retry、丢包、并发 stream 和 key phase 是状态不变量；不解析 hostname、不打开 UDP。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
