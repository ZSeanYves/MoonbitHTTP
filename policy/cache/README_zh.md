# `policy/cache`

[English](README.md) · [项目说明](../../README_zh.md)

`HttpCache` 提供有容量限制的内存响应缓存。向 `store` 传入请求头、响应头、正文字节和当前 Unix 时间（秒）。`lookup` 根据新鲜度和 `Vary` 匹配缓存；对过期条目，可使用命中结果中的校验字段发起条件请求，收到 304 后调用 `revalidate`。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/policy/cache",
  "ZSeanYves/http/core/types",
} for "test"
```

将示例保存为 `example_test.mbt`。

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
