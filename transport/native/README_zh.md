# `transport/native`

Status: canonical
Scope: public Native TCP, UDP, resolver, and clock adapters
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
使用 Native socket 和系统 resolver 实现 transport 契约。

## 入口
入口是 TcpConnector、NativeResolver、UdpSocket、UdpServerSocket、NativeClock。

## 依赖与目标
依赖 transport、types、async/socket，仅支持 native；TLS 和 HTTP state 独立。

## 使用边界
通过 NativeResolver 解析，每个数字结果都经 NetworkPolicy 授权后再交给 connector；时间相关逻辑使用显式 clock。

## 不变量与范围
hostname 解析显式进行；TCP/UDP connect 需要数字 endpoint，policy 与 datagram 上限在 host I/O 前执行。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
