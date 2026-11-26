# `core/body`

[English](README.md) · [项目说明](../../README_zh.md)

`Body` 由消费方按需读取数据帧和尾部字段。已知内容可用 `EmptyBody` 或 `FullBody`，按需生产数据可用 `BodyStream::from_pull`。通常逐帧消费；需要完整正文时可用 `collect` 指定字节上限。提前放弃读取时应取消流。 下方异步示例在 Native、Wasm 和 JavaScript 上运行，Wasm-GC 仅验证编译。

`collect` 返回 `(bytes, trailers)`。正文超过 `max_bytes` 时，它会取消正文并抛出 `BodyLimitExceeded`。

在 `moon.pkg` 中导入

```moonbit
import {
  "moonbitlang/core/async",
  "ZSeanYves/http/core/body",
} for "test"

options(
  "allow-experimental-packages": ["moonbitlang/core/async"],
)
```

将示例保存为 `example_test.mbt`。

```moonbit
async test "collect a small body" {
  let (bytes, trailers) = @body.collect(
    @body.FullBody::new(b"hello"),
    max_bytes=8,
  )
  assert_eq(bytes, b"hello")
  assert_true(trailers is None)
}
```
