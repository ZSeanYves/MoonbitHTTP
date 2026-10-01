# `body`

Status: canonical
Scope: public core body and backpressure contract
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
定义与协议无关的 Body、Frame、SizeHint、有界队列、取消和显式收集。

## 入口
入口是 EmptyBody、FullBody、QueueBody、BodyStream、from_pull、collect 以及 Body trait。

## 依赖与目标
依赖 types 和异步队列，面向四个编译目标。

## 使用边界
已知字节用 FullBody，有限帧用 QueueBody，并发生产消费用有界 BodyStream；collect 必须给出上限。

## 不变量与范围
保留 Data、Trailers、完成、取消和终止错误；队列与收集均有上限，framing 仍由协议包负责。

## 规范文档
- [中文总览](../README_zh.md)
- [包地图](../docs/concepts/packages.md)
- [架构](../docs/concepts/architecture.md)
