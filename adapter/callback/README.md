# `adapter/callback`

[中文](README_zh.md) · [Project README](../../README.md)

Wrap host-provided async read and write callbacks as a MoonBit binary stream. Each callback receives a buffer, offset and length, and returns the number of bytes transferred. A zero read signals EOF. Writes must make progress. Use the optional close callback to release the host resource. For HTTP/3, provide separate datagram and QUIC TLS capabilities. The async example runs on Native, Wasm and JavaScript. Wasm-GC has compile-only coverage for this example.

Pass `close_callback` to release the host stream. Repeated calls to `close()` invoke it only once.

In `moon.pkg`

```moonbit
import {
  "moonbitlang/core/async",
  "ZSeanYves/http/adapter/callback",
} for "test"

options(
  "allow-experimental-packages": ["moonbitlang/core/async"],
)
```

Save as `example_test.mbt`.

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
