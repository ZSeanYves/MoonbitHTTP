# `application/client`

[English](README.md) · [项目说明](../../README_zh.md)

用 `Client::send` 发送逻辑请求。客户端在作用域内复用认证状态、Cookie 和缓存。三个协议可以使用相同的应用代码。可移植宿主使用 `with_client` 注入单次交换函数、墙钟、单调时钟和重定向授权。Native 用户可使用[原生工厂](../../adapter/native/client/README_zh.md)。

```moonbit
pub async fn get(client : @client.Client, uri : @types.Uri) -> Bytes {
  let request = client.request(Get, uri, @client.Upload::bytes(b""))
  let response = client.send(request)
  let (data, _) = @body.collect(response.body, max_bytes=1024 * 1024)
  data
}
```

示例使用 `application/client`、`core/types` 和 `core/body`。用 `Upload::once(body)` 发送一次性流，用 `Upload::reopen(factory)` 提供可重新读取的同一实体。工厂仅在实际发送时调用。逐帧读取响应可保留背压和 trailers，提前退出时调用 `response.body.cancel(reason)`。

重定向、重试、认证和缓存由同一个客户端处理。缓存只提交完整表示；内容解码与 Digest 验证出错会终止读取。Digest `auth-int` 响应受正文上限约束，验证后才交付。总时限覆盖读取响应的整个生命周期。

直接驱动连接时，H1、H2 使用各自池的 `execute_body`，H3 使用 `Http3Client::send`。这些入口各执行一次协议交换。
