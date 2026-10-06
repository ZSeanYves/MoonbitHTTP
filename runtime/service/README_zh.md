# `service`

Status: canonical
Scope: public async HTTP/1 and HTTP/2 service drivers
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
把 HTTP/1、HTTP/2 state machine 接到 async Reader/Writer，覆盖 h2c、并发 dispatch、背压、deadline 和作用域关闭。

## 入口
入口是 serve_http1_connection、serve_http1_or_h2c_connection、serve_http2_connection、serve_auto_connection、ClientConnection、with_h2_client_connection。

## 依赖与目标
依赖 core/types、core/body、protocol/http1、protocol/http2、runtime/detection；socket 由 adapter 提供，这里不隐式提供 HTTP/3 service。

## 使用边界
传入 Reader、Writer、handler 和已校验 config；handler 使用 Request[BodyStream] -> Response[B]，H2 body 在 callback 内消费。

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

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
