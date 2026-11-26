# `internal/http_fields`

[English](README.md) · [项目说明](../../README_zh.md)

HTTP/2 和 HTTP/3 共用的请求目标与普通字段规则。编码请求时，`request_target` 解析 `pseudo_fields` 要使用的 authority 和资源路径。字段语法检查通过后，再用 `Section::allows` 判断该字段能否出现在请求头、响应头或尾部字段中。

应用读写 HTTP 字段时使用 `core/types` 的 `HeaderMap`。[HTTP 类型](../../core/types/README_zh.md)
