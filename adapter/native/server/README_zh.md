# `adapter/native/server`

Status: canonical
Scope: public Native TCP listener adapter
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
为通用 server.Listener 提供有 network policy 的 Native TCP bind、accept 和可选 TLS listener。

## 入口
使用 `NativeTcpListener::bind` 接收 TCP 连接，使用 `bind_tls` 接收完成握手的连接，或使用 `bind_http_tls` 直接处理 HTTP 请求。`bind_http_tls` 按 ALPN 选择 HTTP/1.1 或 HTTP/2，配置允许 HTTP/1.1 时也可接受未协商 ALPN 的客户端。将监听器交给 `ServerSupervisor::serve` 管理并发和关闭。

处理成功后，监听器发出 TLS 关闭通知。`shutdown_timeout_ms` 控制发送期限，默认 1,000 毫秒。处理失败或任务取消时立即关闭传输。

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
