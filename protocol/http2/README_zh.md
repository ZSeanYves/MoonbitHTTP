# `http2`

Status: canonical
Scope: public HTTP/2 codec and state package
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
实现 frame、HPACK、stream/connection state、SETTINGS、GOAWAY/RST 和有界流控，不做 I/O。

## 入口
入口是 FrameDecoder、H2Connection、HpackContext、H2Frame 和 frame encoder；并发 I/O 使用 service。

## 依赖与目标
依赖 types 和 codec，面向四个编译目标。

## 使用边界
显式设定 role 和 limits，输入 frame 并执行返回 action；body 背压留在 service 边界。

## 不变量与范围
状态改变前校验 frame 大小、stream ID、伪字段、SETTINGS 角色、HPACK 和双层流控。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
