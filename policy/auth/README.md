# `policy/auth`

[中文](README_zh.md) · [Project README](../../README.md)

Parse authentication challenges and build Authorization header values for Basic, Bearer and Digest authentication. Pass the returned `HeaderValue` to the request headers for the intended origin. A Digest session tracks the challenge and nonce count between requests.

For a Digest challenge with `stale=true`, `DigestSession::replace_stale_challenge` updates the session before the next authorization is generated.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/policy/auth",
} for "test"

supported_targets = "js+native+wasm+wasm-gc"
```

Save as `example_test.mbt`.

```moonbit
test "format a bearer credential" {
  let token = @auth.BearerToken::new("example-token").unwrap()
  assert_eq(
    token.authorization().unwrap().to_string_lossy(),
    "Bearer example-token",
  )
}
```
