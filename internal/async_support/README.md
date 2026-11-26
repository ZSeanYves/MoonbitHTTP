# `internal/async_support`

[中文](README_zh.md) · [Project README](../../README.md)

Shared async helpers used by the service and adapter implementations. `read_some` reads at most the supplied number of bytes from a `BinaryReader`, `io_cause` extracts the underlying I/O error, and `with_group_result` carries a result out of a scoped task group. Applications integrating connection handlers can use the [service package](../../runtime/service/README.md).
