# `cache`

Status: canonical
Scope: public optional HTTP caching policy
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
解析缓存元数据并执行有界的新鲜度、条件请求、再验证和失效决策，不做网络或文件 I/O。

## 入口
入口是 HttpCache、CacheConfig、CacheLimits、CacheHit 及缓存解析函数。

## 依赖与目标
依赖 types，面向四个编译目标，是客户端可选策略。

## 使用边界
使用 HttpCache::new 创建实例，显式传入时钟值并通过方法处理元数据。

## 不变量与范围
条目、指令、字段和字节均受限；不决定重试，也不负责持久化。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
