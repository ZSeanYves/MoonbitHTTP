# `cmd/h3_smoke_server`

Status: development
Scope: Native HTTP/3 interoperability executable
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
提供有界 loopback UDP fixture 用于 HTTP/3/QUIC 互操作，不是库或通用服务器。

## 入口
由 tools/http3_interoperability.mbtx 启动，绑定 127.0.0.1:18443 并提供有限 GET/POST。

## 依赖与目标
使用 transport/native、tls/native、quic、http3，仅支持 native；四目标编译不等于 UDP 运行。

## 使用边界
让仓库 runner 负责启动和停止；内置凭据绝不可用于部署。

## 不变量与范围
连接、body、stream、UDP 工作均有界；结果是互操作证据，不是压力或性能保证。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
