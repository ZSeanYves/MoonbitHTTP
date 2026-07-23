# ZSeanYves/MoonbitHTTP

MoonbitHTTP 0.4.0 是一个传输层无关、可流式驱动的 MoonBit HTTP 协议库。
核心 codec 是纯增量状态机，可在四个稳定后端运行；异步连接层直接使用
`moonbitlang/async/io.Reader` 与 `Writer`，可接 TCP、内存 pipe 或外部运行时。

## 包结构

| 包 | 职责 |
| --- | --- |
| `types` | 多值 HeaderMap、Method、Uri、Version、泛型 Request/Response、Limits |
| `body` | 异步 `Body` trait、Data/Trailers frame、SizeHint、收集与限制 |
| `codec` | 与协议无关的增量字节缓冲和结构化 codec 错误 |
| `http1` | RFC 9110/9112 framing、流式事件、pipeline、请求/响应编码 |
| `http2` | 帧、完整 HPACK Huffman/动态表、连接/流状态和流量控制 |
| `service` | 异步 HTTP/1、HTTP/2、自动协议 server，以及 HTTP/1 client connection |
| `auto` | HTTP/2 prior knowledge、h2c 和外部 ALPN 选择 |
| `uv_adapter` | callback/uv 风格 I/O 到官方 Reader/Writer 的薄适配 |
| `test_support` | 分片、故障注入和录制 I/O 测试工具 |

## 异步 HTTP/1 服务端

```moonbit
async fn serve_connection[R : @io.Reader, W : @io.Writer](reader : R, writer : W) {
  @service.serve_http1_connection(reader, writer, async fn(request) {
    let headers = @types.HeaderMap::new()
    ignore(headers.append_string("content-type", "text/plain"))
    {
      status: 200,
      version: request.version,
      headers,
      body: b"Hello from MoonbitHTTP!",
    }
  })
}
```

用户 service 抛出的错误默认原样向上传播。只有调用
`serve_http1_with_error_responder` 并显式提供映射策略时，库才会把错误转换为
HTTP 响应。

## 真实 socket 验证

仓库提供 native smoke server，可同时处理 HTTP/1.1、HTTP/2 prior knowledge
和 h2c Upgrade：

```bash
bash scripts/interoperability.sh
```

脚本使用 curl 和 nghttp2 对真实 TCP 连接做互操作验证。

## 开发验证

```bash
moon fmt --check
moon check --target all --deny-warn --warn-list +73
moon test --target all --deny-warn --warn-list +73
moon bench --build-only --target native --deny-warn --warn-list +73
```

当前架构、协议覆盖范围和验证基线见
[维护实施报告](./docs/maintenance-plan.md)。

## 许可证

Apache License 2.0，见 [LICENSE](./LICENSE)。
