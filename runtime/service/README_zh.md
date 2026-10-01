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

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
