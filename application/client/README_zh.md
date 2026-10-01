# `client`

Status: canonical
Scope: public high-level client policy and HTTP/1 pooling
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
组合请求选项、重定向、重试、代理、可选认证、Cookie、缓存、内容解码和有界 HTTP/1 连接池。

## 入口
入口是 Http1Client::from_capabilities/send、Http1PooledRoundTripper、RequestOptions、ProxyConfig、RetryPolicy、RedirectPolicy、ConnectionPool。

## 依赖与目标
组合 core/types、core/body、runtime/transport、protocol/http1、runtime/service 与可选策略，四目标可编译；联网必须注入宿主能力。

## 使用边界
显式传入 connector、resolver、TLS、policy、clock；需要保留 response body 所有权时使用流式 round trip。

## 不变量与范围
解析结果在连接前再次授权；重试和重定向保持可重放性与限制。目前高层入口覆盖 HTTP/1，HTTP/2/3 驱动仍分开。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
