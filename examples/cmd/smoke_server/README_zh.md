# `examples/cmd/smoke_server`

Status: development
Scope: Native HTTP service smoke executable
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
运行本地 socket 检查使用的有界 HTTP/1 与 h2c service fixture。

## 入口
通过仓库互操作 runner 运行 moon run examples/cmd/smoke_server。

## 依赖与目标
依赖 service、body、types 和 async socket，仅支持 native。

## 使用边界
使用仓库 runner 控制端口、进程生命周期和客户端用例。

## 不变量与范围
不定义另一套协议实现，也不提供生产配置面。

## 规范文档
- [中文总览](../../../README_zh.md)
- [包地图](../../../docs/concepts/packages.md)
- [架构](../../../docs/concepts/architecture.md)
