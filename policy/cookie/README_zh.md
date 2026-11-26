# `policy/cookie`

[English](README.md) · [项目说明](../../README_zh.md)

需要保存 Set-Cookie 并为后续请求选择 Cookie 时，显式启用 `CookieJar`。每次操作传入请求 URI 和当前 Unix 时间（秒）。Cookie 匹配考虑域名、路径、过期时间和 Secure 属性；涉及 SameSite 时使用 `CookieContext` 提供请求上下文。

IP 来源设置 Cookie 时须省略 `Domain`，之后 Cookie 可取回并发给同一主机。对 IPv4 或 IPv6 字面量查询公共后缀会返回 `IpAddressHasNoPublicSuffix`。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/policy/cookie",
  "ZSeanYves/http/core/types",
} for "test"

supported_targets = "js+native+wasm+wasm-gc"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "send a cookie over HTTPS" {
  let uri = @types.Uri::parse("https://example.com/account").unwrap()
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let _ = jar.store_string("id=42; Secure; Path=/", uri, 0L).unwrap()
  let value = jar.cookie_header(uri, 1L).unwrap().unwrap()
  assert_eq(value.to_string_lossy(), "id=42")
}
```
