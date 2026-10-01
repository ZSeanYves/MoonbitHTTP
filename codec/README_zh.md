# `codec`

Status: canonical
Scope: public protocol-independent codec primitives
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
提供有界增量字节缓冲、行/前缀检查、结构化错误和共享 Huffman 编解码。

## 入口
入口是 Buffer::new/feed/read_line/take 以及 huffman_encode/decode。

## 依赖与目标
无本地包依赖，面向四个编译目标。

## 使用边界
给 Buffer 明确上限并接受任意分片；在协议边界转换 CodecError。

## 不变量与范围
缓冲增长有界；Huffman 拒绝非法 code、数据中的 EOS 和非法 padding；字段规则由协议包负责。

## 规范文档
- [中文总览](../README_zh.md)
- [包地图](../docs/concepts/packages.md)
- [架构](../docs/concepts/architecture.md)
