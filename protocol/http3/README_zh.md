# `http3`

Status: canonical
Scope: public HTTP/3 codec, state, and driver
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
实现 HTTP/3 frame、字段、SETTINGS、控制流、QPACK、request stream、connection state 和 QUIC stream action。

## 入口
入口是 Http3Connection、Http3Driver、frame 类型、QpackField 以及 QPACK encoder/decoder。

## 依赖与目标
依赖 types、codec、quic；协议核心面向四目标，联网仍需宿主 adapter。

## 使用边界
显式设置 role/settings/limits，输入所属 QUIC stream event 并执行 action。

## 不变量与范围
统一检查 critical stream、重复字段、CONNECT gate、QPACK、body 长度和 request 生命周期；不做 socket。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
