# `adapter/native/server`

Status: canonical
Scope: public Native TCP and UDP listener adapters
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
为 HTTP/1、HTTP/2 和 HTTP/3 提供遵循网络策略的原生监听器，并由 ServerSupervisor 管理连接的接纳和关闭。

## 入口
使用 `NativeTcpListener::bind` 接收 TCP 连接，使用 `bind_tls` 接收完成握手的连接，或使用 `bind_http_tls` 直接处理 HTTP 请求。`bind_http_tls` 按 ALPN 选择 HTTP/1.1 或 HTTP/2，配置允许 HTTP/1.1 时也可接受未协商 ALPN 的客户端。将监听器交给 `ServerSupervisor::serve` 管理并发和关闭。

TCP 上的 TLS 处理成功后，监听器发出关闭通知。`shutdown_timeout_ms` 控制发送期限，默认 1,000 毫秒。处理失败或任务取消时立即关闭传输。

`NativeHttp3Listener::bind` 接受数字 UDP 端点、网络策略、使用 h3 ALPN 的 TLS 1.3 配置和连接回调，绑定后调用 `serve(supervisor)`。Initial 重传按来源和初始目的 ID 归属，后续数据报使用随机生成的 16 字节服务端连接 ID。每个连接有独立的有界队列，队列满时由 QUIC 负责后续重传。调用 supervisor 的 `begin_shutdown` 会停止接纳新连接，监听器继续收发已接纳连接的数据和确认，直到现有处理完成。应用回调按流 ID 分发请求。

## 依赖与目标
本包仅支持 Native。`application/server` 管理接纳和关闭，`runtime/service` 驱动连接，原生适配器提供套接字和 TLS。

## 使用边界
传入数字 bind endpoint、NetworkPolicy 和 handler；peer 在交给 handler 前授权，TLS 需握手完成。

## 不变量与范围
policy 拒绝必须先于 socket 创建或 handler；adapter 负责 socket close/握手 timeout，不负责协议状态机。

## 规范文档
- [中文总览](../../../README_zh.md)
- [包地图](../../../docs/concepts/packages.md)
- [架构](../../../docs/concepts/architecture.md)
