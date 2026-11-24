# `core/types`

[English](README.md) · [项目说明](../../README_zh.md)

构造三个 HTTP 版本共用的请求和响应。`Request[B]` 和 `Response[B]` 的正文类型由调用方选择。`Uri` 解析请求目标，`HeaderMap` 保留重复字段，按名称查找时忽略大小写。字段值以字节保存，显示时可以使用 `to_string_lossy()`。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/core/types",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "look up a header" {
  let headers = @types.HeaderMap::new()
  headers.append_string("Content-Type", "text/plain").unwrap()
  let value = headers.get_string("content-type").unwrap()
  assert_eq(value.to_string_lossy(), "text/plain")
}
```
