# ZSeanYves/MoonbitHTTP

## 概览

**MoonbitHTTP** 是一个基于 [MoonBit](https://www.moonbitlang.com/) 的 HTTP 协议工具库集合，目标是模块化、可测试、可扩展。
它分为多个子包，每个子包有独立的说明文档和 API：

* [`http/core`](./src/core/README.md)：HTTP 核心数据结构（请求/响应、状态码、消息体、限制参数）
* [`http/transport`](./src/transport/README.md)：轻量的内存传输层和缓冲游标，方便测试与增量解析
* [`http/http1`](./src/http1/README.md)：HTTP/1.1 协议解析与编解码（请求/响应、服务端/客户端工具）
* [`http/http2`](./src/http2/README.md)：HTTP/2（规划中/开发中）

每个子包的详细说明、使用示例和 API 请查看各自目录下的 **README.md**。

---

## 特性

* **模块化设计**：核心、传输层、HTTP/1.1、HTTP/2 相互解耦
* **易于测试**：全部支持在内存中模拟，不依赖真实网络（后续会加入真实网络）
* **渐进增强**：从简单的 `Content-Length` 响应到 `chunked`，再到多路复用的 HTTP/2
* **生态兼容**：依赖 [`bufferutils`](https://github.com/ZSeanYves/BufferUtils) 等工具库

---

## 下载

```bash
moon add ZSeanYves/MoonbitHTTP
```

或编辑 `moon.mod.json`：

```json
"import": ["ZSeanYves/MoonbitHTTP"]
```

---

## 示例

最简单的例子：启动一个内存传输的服务端，解析请求并返回响应。

```moonbit
use http/core
use http/http1 { serve_once, StatusCode }
use @tsp = @ZSeanYves/MoonbitHTTP/transport
use @buf = @ZSeanYves/bufferutils

fn hello(_req: Request) -> (StatusCode, Map[String,String], Array[Byte], Bool) {
  let hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")
  let body = @buf.string_to_utf8_bytes("Hello from MoonbitHTTP!").to_array()
  (StatusCode::OK, hs, body, false)
}

let rx = @buf.string_to_utf8_bytes("GET / HTTP/1.1\r\nHost: a\r\n\r\n").to_array()
let io = @tsp.from_inmemory(rx)
let _  = serve_once(io, hello, 32, 1024, 4096)
println(Bytes::from_array(io.take_tx()).to_string())
```

---

## 路线图

* [x] `http/core`：核心类型
* [x] `http/transport`：内存传输层
* [x] `http/http1`：HTTP/1.1 协议支持
* [ ] `http/http2`：HTTP/2 协议支持

---

## 许可证

MIT License. 详见 [LICENSE](./LICENSE)。

---