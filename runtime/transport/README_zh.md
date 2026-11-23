# `transport`

Status: canonical
Scope: public host-capability contracts
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
定义 stream/datagram I/O、解析、network policy、clock、entropy、TLS、QUIC-TLS、endpoint 和类型化错误契约。

## 入口
入口是 StreamConnection、Datagram、DatagramSocket、NameResolver、NetworkPolicy、Clock、Entropy、TlsProvider、QuicTlsProvider。

## 依赖与目标
依赖 types 与 portable async，面向四目标；具体 adapter 独立。

## 使用边界
将所有 capability 显式传入 application/client、runtime/service、application/server、protocol/quic，并在构造边界校验 options 和 policy。

## 不变量与范围
`resolve_endpoints` 接受端点、查询回调和 `ResolveOptions`。数字地址直接返回。主机名查询受超时和结果数量限制，候选地址按解析顺序去重，保留原 scheme 和端口。调用方负责在查询和连接前分别检查策略。

## 规范文档
- [中文总览](../../README_zh.md)
