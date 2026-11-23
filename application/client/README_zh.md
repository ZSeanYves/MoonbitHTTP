# `client`

Status: canonical
Scope: public high-level client policy and HTTP/1 and HTTP/2 pooling
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
组合请求选项、重定向、重试、代理、可选认证、Cookie、缓存、内容解码和有界 HTTP/1、HTTP/2 连接池。

## 入口
入口是 Http1Client::from_capabilities/send、Http1PooledRoundTripper、with_http2_client、RequestOptions、ProxyConfig、RetryPolicy、RedirectPolicy、ConnectionPool。

## 依赖与目标
组合 core/types、core/body、runtime/transport、protocol/http1、protocol/http2、runtime/service 与可选策略，四目标可编译；联网必须注入宿主能力。

## 使用边界
显式传入 connector、resolver、TLS、policy、clock；需要保留 response body 所有权时使用流式 round trip。

将 `Request[B]`（`B : Body`）传给 `Http1PooledRoundTripper::execute_body`，可执行一次流式上传并流式读取响应。HTTP/1.1 请求大小未知时使用 chunked 编码，可发送 trailers。每帧写完才拉取下一帧，读完或取消响应体会释放连接池租约。自动重试、重定向和缓存由字节接口 `Http1Client::send` 提供。

## 不变量与范围
每次建连前都对 DNS 返回的数字地址授权。`with_http2_client` 按源站共享建连及 HTTP/2 会话，收到对端初始 SETTINGS 后才调度请求。HTTPS 要求协商 `h2`，明文连接使用 prior knowledge。`Http2PoolOptions.max_connections` 限制物理连接总数，含正在建连和收到 GOAWAY 后仍在完成请求的连接。`execute` 返回有大小上限的字节响应，`execute_body` 支持流式上传和响应。在作用域内读完或取消响应体，退出时连接和后台任务统一回收。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
