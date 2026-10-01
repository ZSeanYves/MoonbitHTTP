# `adapter/native/server`

Status: canonical
Scope: public Native TCP listener adapter
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
为通用 server.Listener 提供有 network policy 的 Native TCP bind、accept 和可选 TLS listener。

## 入口
入口是 NativeTcpListener::bind 与 bind_tls，显式传入 TLS、timeout 和 policy。

## 依赖与目标
依赖 server、transport、types 和 Native async socket，仅支持 native。

## 使用边界
传入数字 bind endpoint、NetworkPolicy 和 handler；peer 在交给 handler 前授权，TLS 需握手完成。

## 不变量与范围
policy 拒绝必须先于 socket 创建或 handler；adapter 负责 socket close/握手 timeout，不负责协议状态机。

## 规范文档
- [中文总览](../../../README_zh.md)
- [包地图](../../../docs/concepts/packages.md)
- [架构](../../../docs/concepts/architecture.md)
