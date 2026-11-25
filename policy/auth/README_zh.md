# `policy/auth`

[English](README.md) · [项目说明](../../README_zh.md)

解析认证质询，并为 Basic、Bearer 和 Digest 生成 Authorization 字段值。调用方将返回的 `HeaderValue` 加入发往指定源站的请求。使用 Digest 时可通过会话跟踪质询与 nonce 计数。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/policy/auth",
} for "test"

supported_targets = "js+native+wasm+wasm-gc"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "format a bearer credential" {
  let token = @auth.BearerToken::new("example-token").unwrap()
  assert_eq(
    token.authorization().unwrap().to_string_lossy(),
    "Bearer example-token",
  )
}
```
