# `core/types`

[中文](README_zh.md) · [Project README](../../README.md)

Construct requests and responses shared by HTTP/1.0, HTTP/1.1, HTTP/2 and HTTP/3. `Request[B]` and `Response[B]` carry the body type you choose. `Uri` parses request targets, and `HeaderMap` preserves repeated fields and matches names case-insensitively. Header values are bytes. Use `to_string_lossy()` for display.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/core/types",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "look up a header" {
  let headers = @types.HeaderMap::new()
  headers.append_string("Content-Type", "text/plain").unwrap()
  let value = headers.get_string("content-type").unwrap()
  assert_eq(value.to_string_lossy(), "text/plain")
}
```
