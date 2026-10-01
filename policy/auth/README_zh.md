# `auth`

Status: canonical
Scope: public optional policy
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
处理 Basic、Bearer 和 Digest 凭据及授权，不打开连接，也不实现协议驱动。

## 入口
入口是 BasicCredentials、BearerToken、DigestChallenge、DigestSession、DigestPolicy、AuthLimits 和 select_digest_challenge。

## 依赖与目标
依赖 types 与哈希支持，面向 Native、Wasm、Wasm-GC、JS。

## 使用边界
使用 new 构造并校验凭据，再取得 HeaderValue；处理 Digest challenge 时显式传入策略和限制。

## 不变量与范围
凭据和 challenge 有大小上限；弱算法、未支持的 qop/charset 按策略拒绝；不持久化凭据。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
