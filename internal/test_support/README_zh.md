# `internal/test_support`

Status: development
Scope: test and white-box support; not a v1 runtime API
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
为协议和 transport 测试提供分片、故障注入、录制 writer、内存 datagram、固定时钟和零 entropy。

## 入口
测试入口是 fragment、FaultReader、RecordingWriter、MemoryDatagramSocket、FixedClock、ZeroEntropy。

## 依赖与目标
依赖 transport、async I/O、types；可供测试导入但不承诺 v1 兼容。

## 使用边界
将 fixture 注入 core/codec、protocol driver 和 capability，并断言可观察 action；显式保留失败和边界。

## 不变量与范围
fixture 必须确定且有界；ZeroEntropy 和内存 socket 绝不可作为生产安全或网络 provider。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
