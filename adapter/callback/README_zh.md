# `adapter/callback`

[English](README.md) · [项目说明](../../README_zh.md)

将宿主提供的异步读写回调包装为 MoonBit 二进制流。回调接收缓冲区、偏移和长度，返回实际传输字节数。读取返回零表示 EOF，写入必须取得进展。可用关闭回调释放宿主资源。HTTP/3 还需要单独提供数据报和 QUIC TLS 能力。 下方异步示例在 Native、Wasm 和 JavaScript 上运行，Wasm-GC 仅验证编译。

在 `moon.pkg` 中导入

```moonbit
import {
  "moonbitlang/core/async",
  "ZSeanYves/MoonbitHTTP/adapter/callback",
} for "test"

options(
  "allow-experimental-packages": ["moonbitlang/core/async"],
)
```

将示例保存为 `example_test.mbt`。

```moonbit
async test "forward bytes to the host" {
  let mut written = 0
  let stream = @callback.CallbackTransport::new(fn(_, _, _) { 0 }, fn(
    _,
    _,
    length,
  ) {
    written += length
    length
  })
  stream.write(b"hello")
  stream.close()
  assert_eq(written, 5)
}
```
