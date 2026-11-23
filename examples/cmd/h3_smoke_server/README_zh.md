# `examples/cmd/h3_smoke_server`

Status: development
Scope: Native HTTP/3 interoperability executable
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
提供有界 loopback UDP fixture 用于 HTTP/3/QUIC 互操作，不是库或通用服务器。

## 入口
由 repo-tools/tools/http3_interoperability.mbtx 启动，绑定 127.0.0.1:18443 并提供有限 GET/POST。

传入 `--once` 后，第一个请求进入处理器时立即触发 supervisor 停机。服务端发出 GOAWAY，继续收完上传、发完响应后退出，独立客户端可据此验证停机期间的传输。

处理 POST 时，服务端先请求对端更换目标连接 ID，再回显请求体。请求流的初始窗口为 256 字节，因此测试上传的 4,096 字节会跨越这次轮换。

## 依赖与目标
通过 `NativeHttp3Listener::bind` 取得连接，并用 `serve_http3_connection` 运行流式请求处理器。实际收发依赖原生 UDP 和 OpenSSL QUIC TLS provider。

## 使用边界
让仓库 runner 负责启动和停止；内置凭据绝不可用于部署。

## 不变量与范围
连接、body、stream、UDP 工作均有界；结果是互操作证据，不是压力或性能保证。

## 规范文档
- [中文总览](../../../README_zh.md)
