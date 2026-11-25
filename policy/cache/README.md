# `policy/cache`

[中文](README_zh.md) · [Project README](../../README.md)

Use `HttpCache` for a bounded in-memory response cache. Give `store` the request and response heads, body bytes and current Unix time in seconds. `lookup` accounts for freshness and `Vary`. For stale entries, use the validators from the hit to make a conditional request and apply a 304 response with `revalidate`.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/policy/cache",
  "ZSeanYves/http/core/types",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "reuse a fresh response" {
  let cache = @cache.HttpCache::new().unwrap()
  let request : @types.Request[Unit] = {
    http_method: Get,
    uri: @types.Uri::parse("https://example.com/").unwrap(),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: (),
  }
  let headers = @types.HeaderMap::new()
  headers.append_string("cache-control", "max-age=60").unwrap()
  let response : @types.Response[Unit] = {
    status: 200,
    version: Http11,
    headers,
    body: (),
  }
  let _ = cache.store(request, response, b"hello", 100L).unwrap()
  guard cache.lookup(request, 110L) is Ok(CacheFresh(hit)) else {
    fail("expected a cache hit")
  }
  assert_eq(hit.body(), b"hello")
}
```
