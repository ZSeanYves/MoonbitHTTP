# `cookie`

Status: canonical
Scope: public optional cookie and public-suffix policy
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
解析 Cookie 字段，执行 domain/path/SameSite 规则，并在 CookieJar 中保存有界客户端状态。

## 入口
入口是 CookieJar、CookieContext、CookieLimits、store/store_string、cookie_header 和 public-suffix helper。

## 依赖与目标
依赖 types、IDNA 和 public-suffix 数据，面向四个编译目标。

## 使用边界
显式启用并设置限制；保存响应 Cookie 时传入 URI 和时钟值，按目标 URI 请求 cookie_header。

## 不变量与范围
非法域名、超大值、public-suffix 违规和 SameSite 约束会被拒绝；不负责持久化。

## 规范文档
- [中文总览](../README_zh.md)
- [包地图](../docs/concepts/packages.md)
- [架构](../docs/concepts/architecture.md)
