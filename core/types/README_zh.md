# `types`

Status: canonical
Scope: public protocol-independent data and error core
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
拥有经过校验的 Request、Response、HeaderMap、method、version、Uri、Authority、IP、endpoint、date、limits 和共享错误。

## 入口
入口是 HeaderMap、Uri、Authority、Endpoint、IpAddress、Limits 以及泛型 Request[B]/Response[B]。

## 依赖与目标
无本地包依赖，面向四个编译目标。

## 使用边界
通过校验构造器创建值并传播类型化错误；body 参数保持泛型，直到上层选择 Body 实现。

## 不变量与范围
构造时校验 header name、URI authority、IP literal、method 和 limits；不包含 framing、socket、TLS、resolver、policy。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
