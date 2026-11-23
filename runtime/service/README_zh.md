# `service`

Status: canonical
Scope: async HTTP/1, HTTP/2 and HTTP/3 connection drivers
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
把 HTTP/1、HTTP/2 state machine 接到 async Reader/Writer，覆盖 h2c、并发 dispatch、背压、deadline 和作用域关闭。

## 入口
入口是 serve_http1_connection、serve_http1_or_h2c_connection、serve_http2_connection、serve_auto_connection、ClientConnection、with_h2_client_connection。

## 依赖与目标
HTTP/3 使用可移植的 HTTP/3 与 QUIC 驱动、专用数据报套接字、时钟和 QUIC TLS provider。宿主套接字由 adapter 提供。

## 使用边界
传入 Reader、Writer、handler 和已校验 config；handler 使用 Request[BodyStream] -> Response[B]，H2 body 在 callback 内消费。

`with_http3_connection` 接管套接字，在认证握手完成后调用应用。通过 `io.session` 收发请求和响应，通过 `io.next_events()` 读取事件批次，`io.flush()` 可立即发送待写数据。接收任务和恢复计时器独立运行，交付队列最多保留一个待读批次。回调正常返回后，先等待排队的流数据和 QUIC 确认，再发送关闭包并释放套接字。`shutdown_timeout_ms` 限制等待和最后一次发送的时间，对端正常关闭后，已交付的事件仍可读，消费完后再次读取才收到关闭通知。TLS provider 由调用方管理。

## 不变量与范围
reader task、body queue、流控释放、deadline、取消和 close 均受 service 作用域管理。

读取循环观测到 HTTP/2 对端 EOF 后，正常响应可使用已有发送窗口完成。
`ServerConfig.h2_eof_drain_timeout_ms` 限制 handler、响应体生产者和 writer 的
整体排空时间，默认 30000 ms，必须为正数，h2c 升级同样适用。到期抛出 H2
连接级 `Cancel` 错误，并取消、等待其余任务清理。关闭读写超时不会禁用此期限。
计时仅从观测到 EOF 开始；显式禁用写超时仍允许控制帧写入在此之前阻塞读取循环。
取消采用协作机制：应用代码必须让出执行权，并确保受保护的清理能够结束。
使用完整 `ServerConfig` 字面量的调用方需补充该字段，或使用
`..ServerConfig::defaults()`。

`serve_http3_connection(io, handler)` 为每个接纳的请求运行一个任务，处理器使用 HTTP/1 和 HTTP/2 同款流式请求和响应接口。单个处理器失败会重置对应请求流。响应提前完成时，服务会丢弃该请求余下的正文并归还流控额度。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)

`H2Client::send` 等待本地容量和对端的并发流额度。SETTINGS 提高额度后可恢复等待的请求。GOAWAY 或连接关闭会唤醒等待者并返回错误。请求头已写出时，取消等待响应头的任务会复位对应的流。
