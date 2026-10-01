# `server`

Status: canonical
Scope: public server lifecycle and listener contracts
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
定义 server limits、生命周期、listener/accepted connection contract、监督、关闭和 metrics。

## 入口
入口是 ServerSupervisor、ServerConfig、ServerLimits、Listener、AcceptedConnection、ServerMetrics。

## 依赖与目标
依赖 transport 与 async task；真实 socket 使用 server/native 或其他 listener adapter。

## 使用边界
校验 ServerConfig，启动 Supervisor，传入 listener，并释放每个 accepted connection。

## 不变量与范围
连接上限、accept 错误统计、状态转换和优雅关闭由此负责；不绑定端口、不选择 HTTP framing。

## 规范文档
- [中文总览](../README_zh.md)
- [包地图](../docs/concepts/packages.md)
- [架构](../docs/concepts/architecture.md)
