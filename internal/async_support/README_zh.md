# `internal/async_support`

[English](README.md) · [项目说明](../../README_zh.md)

服务驱动及适配器共用的异步辅助函数。`read_some` 按上限读取，`io_cause` 取出底层 I/O 错误，`with_group_result` 从有作用域的任务组返回结果。应用接入连接处理函数时可使用[服务包](../../runtime/service/README_zh.md)。
