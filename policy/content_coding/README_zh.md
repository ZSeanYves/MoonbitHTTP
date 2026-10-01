# `content_coding`

Status: canonical
Scope: public optional content-coding policy
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
解析并增量解码 gzip、deflate、Brotli 等响应 content coding。

## 入口
入口是 parse_content_codings、ContentCodingLimits、ContentDecoder、decode_response/decode_bytes_response。

## 依赖与目标
依赖 body、types 和 flate/Brotli codec；在依赖可用的四目标环境使用。

## 使用边界
用 ContentCodingLimits 构造限制，解析响应头后使用 decode_response 包装 body。

## 不变量与范围
解码输出独立受限；畸形流返回类型化错误，并在策略边界调整表示头。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
