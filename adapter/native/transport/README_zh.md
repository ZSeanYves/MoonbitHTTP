# `adapter/native/transport`

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
UdpSocket 只接受数字单播目标，IPv4-mapped IPv6 中的组播地址也在创建 socket 前拒绝；UdpServerSocket 保留每个 datagram 的实际来源，并逐次授权 peer 操作。

## 规范文档
- [中文总览](../../../README_zh.md)
- [包地图](../../../docs/concepts/packages.md)
- [架构](../../../docs/concepts/architecture.md)

`NativeResolver` 按系统 `getaddrinfo` 顺序返回去重后的 IPv4 与无作用域 IPv6 地址，上限为 `max_results`。解析在事件循环之外执行。调用超时后即可返回，尚未完成的系统查询继续占用工作线程，进程内最多同时执行 16 个查询。
