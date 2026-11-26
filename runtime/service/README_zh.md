# `runtime/service`

[English](README.md) · [项目说明](../../README_zh.md)

在传入的连接 I/O 上运行 HTTP/1.0、HTTP/1.1、HTTP/2 和 HTTP/3。驱动处理分帧、正文背压和取消。`serve_http1_connection` 接收读取端、写入端及应用的请求处理函数。HTTP/3 需要 QUIC 会话和数据报事件源。应用负责监听端及连接排空时机。

流式处理时，从正文读取尾部字段。使用[应用客户端](../../application/client/README_zh.md)的 H1 或 H2 缓冲 `execute` 时，初始字段在 `headers`，尾部字段在 `trailers`。

在 `moon.pkg` 中导入

```moonbit
import {
  "moonbitlang/core/async/io" @aio,
  "ZSeanYves/http/runtime/service",
  "ZSeanYves/http/core/types",
  "ZSeanYves/http/core/body",
}

options(
  "allow-experimental-packages": ["moonbitlang/core/async/io"],
)
```

将函数放入调用方包的 `.mbt` 文件中。

```moonbit
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter] serve(
  reader : R,
  writer : W,
) -> Unit {
  @service.serve_http1_connection(reader, writer, fn(request) {
    {
      status: 200,
      version: request.version,
      headers: @types.HeaderMap::new(),
      body: @body.FullBody::new(b"ok"),
    }
  })
}
```

## 在连接上处理请求

在同一监听端提供明文 HTTP/1.1 和 HTTP/2 时，可使用 `serve_http1_or_h2c_connection`。对带 `Expect: 100-continue` 且正文待上传的请求，服务端可先返回 100 再读取正文。遇到不支持的期望值，会在调用处理函数前返回 417。

HTTP/3 的 `with_http3_connection` 驱动握手、接收循环和恢复定时器。用 `serve_http3_connection(io, handler)` 分发各请求，用 `on_request_error` 观察处理函数失败。需要优雅关闭时，在这些连接间共享 `ServerShutdown`，调用 `begin()`，并由应用控制宽限时间。
