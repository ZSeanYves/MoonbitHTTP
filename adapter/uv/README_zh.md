# `adapter/uv`

Status: canonical
Scope: public callback-to-async I/O adapter
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
通过 CallbackTransport 将 callback runtime 接到 async Reader/Writer。

## 入口
使用 CallbackTransport::new 传入 read/write/close callback，再显式交给 service。

## 依赖与目标
仅依赖 moonbitlang/async/io；不 pin 或导入特定 uv 版本，也不依赖 Native socket。

## 使用边界
准确转换 callback 的 offset/length，宿主关闭时关闭 adapter，并显式传给 service driver。

## 不变量与范围
关闭后的 transport 拒绝操作，callback 错误保留在 I/O 边界；不选择协议、resolver、TLS 或 policy。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
