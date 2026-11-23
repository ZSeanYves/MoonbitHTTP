# `adapter/native/client`

Status: canonical
Scope: public Native client factory
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
提供 HTTP/1 客户端、HTTP/2 连接池和 HTTP/3 单连接会话的原生入口。

## 入口
使用 `new_http1_client` 创建 HTTP/1 客户端，使用 `with_http2_client` 执行作用域内的 HTTP/2 请求。两者均显式接收 resolver、policy、clock 和 TLS provider。

`with_http3_connection` 接受数字 UDP 端点、网络策略、TLS 配置和应用回调。用 `TlsOptions::for_quic(origin_host)` 验证原站身份并协商 h3。作用域管理 UDP 套接字、随机连接 ID 和 OpenSSL provider。回调可在同一连接上开启多个请求流，从 `H3ConnectionIo` 读取事件。

`with_http3_client` 提供绑定到一个 HTTPS 源的 `H3Client`。`send(request)` 收到最终响应头即可返回 `Response[BodyStream]`，此时请求正文可能仍在上传。在作用域内读完或取消响应。默认使用 TLS 主机名和 UDP 对端端口，逻辑 HTTPS 端口不同时传入 `origin_port`。客户端拒绝其他源，直连时会移除代理凭据。

## 依赖与目标
本包仅支持 Native。HTTP/3 使用 `protocol/http3`、`protocol/quic` 和 `runtime/service`，网络和 TLS 由 `adapter/native/transport` 和 `adapter/native/tls` 提供。

## 使用边界
HTTP/1 和 HTTP/2 使用传入的 resolver 解析主机名。HTTP/3 单独接收数字 UDP 地址和 TLS 身份。三种入口在打开套接字前检查网络策略。

## 规范文档
- [中文总览](../../../README_zh.md)
- [包地图](../../../docs/concepts/packages.md)
- [架构](../../../docs/concepts/architecture.md)
