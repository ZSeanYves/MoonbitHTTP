# `transport`

Status: canonical
Scope: public host-capability contracts
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
定义 stream/datagram I/O、解析、network policy、clock、entropy、TLS、QUIC-TLS、endpoint 和类型化错误契约。

## 入口
入口是 StreamConnection、Datagram、DatagramSocket、NameResolver、NetworkPolicy、Clock、Entropy、TlsProvider、QuicTlsProvider。

## 依赖与目标
依赖 types 与 portable async，面向四目标；具体 adapter 独立。

## 使用边界
将所有 capability 显式传入 application/client、runtime/service、application/server、protocol/quic，并在构造边界校验 options 和 policy。

## 不变量与范围
契约不解析名称、不打开 socket、不选择默认安全策略；可用时错误保留 operation/endpoint。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
