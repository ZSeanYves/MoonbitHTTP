# `application/client`

[English](README.md) · [项目说明](../../README_zh.md)

使用应用提供的传输能力发送请求。字节正文用 `Http1Client::send`，可配置重定向、重试和缓存。单次流式交换用 `Http1PooledRoundTripper::execute_body`，支持分块上传和尾部字段。读完或取消响应正文以释放连接池租约。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/application/client",
  "ZSeanYves/http/core/types",
}

supported_targets = "js+native+wasm+wasm-gc"
```

将函数放入调用方包的 `.mbt` 文件中。

```moonbit
pub async fn get(client : @client.Http1Client, uri : @types.Uri) -> Bytes {
  let response = client
    .send({
      http_method: Get,
      uri,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: b"",
    })
    .unwrap_or_error()
  response.body
}
```

## 多路复用客户端

HTTP/2 使用 `with_http2_pool`。HTTPS 需要协商出 `h2`，明文连接使用先验知识模式。流式交换调用 `execute_body`，有大小上限的字节响应调用 `execute`。HTTP/3 通过 `with_http3_pool` 接入已认证的连接创建函数，再用 `Http3Client::send` 发送绝对 HTTPS URI 请求。连接按源站共享，流式响应应在池的作用域内读完或取消。
