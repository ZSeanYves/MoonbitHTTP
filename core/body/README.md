# `core/body`

[中文](README_zh.md) · [Project README](../../README.md)

`Body` yields data and trailer frames on demand. Use `EmptyBody` or `FullBody` for known content and `BodyStream::from_pull` for a producer. Consume frames as they arrive, or use `collect` with a byte limit when the entire body must fit in memory. Cancel a stream when abandoning it. The async example runs on Native, Wasm and JavaScript. Wasm-GC has compile-only coverage for this example.

In `moon.pkg`

```moonbit
import {
  "moonbitlang/core/async",
  "ZSeanYves/http/core/body",
} for "test"

options(
  "allow-experimental-packages": ["moonbitlang/core/async"],
)
```

Save as `example_test.mbt`.

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
