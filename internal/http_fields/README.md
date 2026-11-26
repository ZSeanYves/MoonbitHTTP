# `internal/http_fields`

[中文](README_zh.md) · [Project README](../../README.md)

HTTP/2 and HTTP/3 share the request-target and regular-field rules in this package. When encoding a request, `request_target` resolves the authority and resource used by `pseudo_fields`. When validating a field, `Section::allows` applies the rules for request, response or trailer sections after syntax checking.

The public field representation is `HeaderMap` in `core/types`. [HTTP types](../../core/types/README.md)
