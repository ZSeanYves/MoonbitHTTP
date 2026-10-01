# `http1`

Status: canonical
Scope: public HTTP/1 codec and state package
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
实现增量 request/response decoder、start-line/字段校验、body framing、trailers 和 encoder，不做 I/O。

## 入口
入口是 RequestDecoder、ResponseDecoder、事件类型和 framing encoder；异步 Reader/Writer 使用 service。

## 依赖与目标
依赖 types 和 codec，面向四个编译目标。

## 使用边界
输入任意分片并消费所有事件，保留 over-read；依据 Body SizeHint 选择 framing。

## 不变量与范围
拒绝歧义长度、非法 trailer、请求走私组合和非法 method/target/header；生命周期由 runtime/service/application/client 负责。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
