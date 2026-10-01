# `client/native`

Status: canonical
Scope: public Native client factory
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
将 Native TCP、resolver、clock、TLS 和 network policy 组装为高层 HTTP/1 client。

## 入口
入口是 new_http1_client，显式传入 resolver、policy、clock 和 TLS provider。

## 依赖与目标
依赖 client、transport、transport/native、content_coding；仅支持 native。

## 使用边界
所有能力都要显式传入；hostname 必须使用 resolver，数字 endpoint 仍在打开 socket 前经 policy 授权。

## 不变量与范围
不提供无 resolver 的 hostname 路径、隐式 policy 或隐藏 TLS provider。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
