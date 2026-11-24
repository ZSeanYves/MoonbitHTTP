# `policy/cookie`

[中文](README_zh.md) · [Project README](../../README.md)

Enable `CookieJar` explicitly to store Set-Cookie values and select cookies for outgoing requests. Supply the request URI and Unix time in seconds for each operation. The jar checks domain, path, expiry and Secure attributes. Supply `CookieContext` when SameSite decisions depend on the request context.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/policy/cookie",
  "ZSeanYves/MoonbitHTTP/core/types",
} for "test"

supported_targets = "js+native+wasm+wasm-gc"
```

Save as `example_test.mbt`.

```moonbit
test "send a cookie over HTTPS" {
  let uri = @types.Uri::parse("https://example.com/account").unwrap()
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let _ = jar.store_string("id=42; Secure; Path=/", uri, 0L).unwrap()
  let value = jar.cookie_header(uri, 1L).unwrap().unwrap()
  assert_eq(value.to_string_lossy(), "id=42")
}
```
