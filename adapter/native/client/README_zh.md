# `adapter/native/client`

Status: canonical
Scope: public Native client factory
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
提供 HTTP/1 客户端、HTTP/2、HTTP/3 连接池和 HTTP/3 单连接会话的原生入口。

## 入口
使用 `new_http1_client` 创建 HTTP/1 客户端，使用 `with_http2_client` 执行作用域内的 HTTP/2 请求。两者均显式接收 resolver、policy、clock 和 TLS provider。

`with_http3_pool(resolver, policy, run)` 接受多个源的绝对 HTTPS 请求，逐源验证证书。`tls` 可指定信任根和客户端证书，设置 `tls.server_name` 会把允许的请求限制在该主机。`max_connections` 默认 32，包含正在握手和排空的连接。GOAWAY 拒绝的请求由调用方决定是否重试。

`with_http3_connection` 接受数字 UDP 端点、网络策略、TLS 配置和应用回调。用 `TlsOptions::for_quic(origin_host)` 验证原站身份并协商 h3。作用域管理 UDP 套接字、随机连接 ID 和 OpenSSL provider。回调可在同一连接上开启多个请求流，从 `H3ConnectionIo` 读取事件。

`with_http3_client` 提供绑定到一个 HTTPS 源的 `H3Client`。`send(request)` 收到最终响应头即可返回 `Response[BodyStream]`，此时请求正文可能仍在上传。在作用域内读完或取消响应。默认使用 TLS 主机名和 UDP 对端端口，逻辑 HTTPS 端口不同时传入 `origin_port`。客户端拒绝其他源，直连时会移除代理凭据。

## 依赖与目标
本包仅支持 Native。HTTP/3 使用 `protocol/http3`、`protocol/quic` 和 `runtime/service`，网络和 TLS 由 `adapter/native/transport` 和 `adapter/native/tls` 提供。

## 使用边界
HTTP/3 的 `with_http3_client` 接受主机名。通过 `resolver=Some(resolver)` 显式传入解析器，用 `TlsOptions::for_quic` 指定原始 HTTPS 身份。客户端在 DNS 查询前检查主机名策略，按返回顺序尝试允许连接的数字地址。候选地址共享握手时间预算，`resolve_options` 控制 DNS 超时和结果数。证书校验失败会立即结束握手，认证成功后应用回调只执行一次。

## 规范文档
- [中文总览](../../../README_zh.md)
- [包地图](../../../docs/concepts/packages.md)
- [架构](../../../docs/concepts/architecture.md)
