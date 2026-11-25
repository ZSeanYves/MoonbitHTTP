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

调用 `response.body.read_batch(64)` 可以一次请求最多 64 帧。读满、收到 trailers 或到达 EOF 时返回。尾部字段只返回一次，空数组表示正文结束。需要逐帧即时处理时使用 `next_frame()`。两种读取方式可以在同一客户端作用域内交替使用。

### 请求生命周期

| 公开操作 | HTTP/1 | HTTP/2 与 HTTP/3 |
| --- | --- | --- |
| 在已就绪会话上写请求头 | 写入使用请求头时限。 | 等待流名额和写完整个请求头共用一次预算。 |
| 上传或读取正文 | 每次受阻读写使用相应正文预算。报文中断后退役连接。 | 生产者、流写入或正文读取受阻时使用对应预算。取消释放该流，同连接其他流可继续。 |
| 等响应头 | 收到最终响应头结束该阶段，超时终止本次交换。 | 收到最终响应头结束该阶段，超时重置请求流。 |
| 服务端开始优雅停服 | 完成已接纳的处理，唤醒空闲连接，跳过已缓冲的后续请求。 | 排空已接纳流并停止接纳新流。 |
| 查看重定向和尾部字段 | 默认返回原响应，显式拒绝返回重定向错误。H1/H2 缓冲接口将头部和尾部字段分开交付。 | 重定向策略相同。流式调用方从正文接口读取尾部字段。 |

TCP 路径分开计算 DNS 和 TCP 建连时限。H3 单独计算 DNS 和 QUIC/TLS 握手时限。H2/H3 等待连接池提供就绪会话后才启动请求头阶段。总预算从逻辑请求开始并覆盖剩余正文消费。Native H1 的套接字读写还使用 `idle_ms`。阶段超时通过 `ClientTimeout` 携带对应的 `ClientPhase`。
