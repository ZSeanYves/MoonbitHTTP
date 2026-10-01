# `auto`

Status: canonical
Scope: public protocol-selection helper
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
无消耗地探测 HTTP/1、HTTP/2 prior knowledge 和 h2c 前缀，只负责分类。

## 入口
入口是 Detector::new/feed/buffered、select_protocol 和 detect_h2c_upgrade。

## 依赖与目标
依赖 types，面向四个编译目标。

## 使用边界
将分片喂给一个 Detector，并把 buffered() 交给选中的 service driver。

## 不变量与范围
探测有界且不消耗输入；不验证完整交换、不选择 HTTP/3、不打开 socket。

## 规范文档
- [中文总览](../README_zh.md)
- [包地图](../docs/concepts/packages.md)
- [架构](../docs/concepts/architecture.md)
