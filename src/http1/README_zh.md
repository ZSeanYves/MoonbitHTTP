# MoonbitHTTP/http1

[![Build Status](https://img.shields.io/github/actions/workflow/status/ZSeanYves/MoonbitHTTP/ci.yml)](https://github.com/ZSeanYves/MoonbitHTTP/actions)
[![License](https://img.shields.io/github/license/ZSeanYves/MoonbitHTTP)](LICENSE)

## 概览

一个面向 MoonBit 项目的模块化、易于测试的 **HTTP/1.1 库**。提供请求解析、响应编码，以及最小化的客户端/服务端工具函数，基于可插拔的传输层（如 [`MoonbitHTTP/transport`](../transport)）。

* **解析器**：逐步解析请求行、头部与消息体。
* **编码器**：生成带有 `Content-Length` 或 `chunked` 编码的响应。
* **服务端工具**：`serve_once` 和 `serve_loop`，把传输层、解析和编码串联起来。
* **客户端工具**：`get`、`post`、`read_response`，便于进行简单的 HTTP/1.1 交互。

本库只包含 **协议逻辑**，不做实际网络通信。适合单元测试，也便于后续扩展。

---

## 使用示例

### 1) 最小服务端：一次请求 → 一次响应

```moonbit
use @tsp = @ZSeanYves/MoonbitHTTP/transport
use @buf = @ZSeanYves/bufferutils
use http/http1 { serve_once, StatusCode }

fn hello(req: Request) -> (StatusCode, Map[String,String], Array[Byte], Bool) {
  println("req line = {}", req.line)
  println("headers = {:?}", req.headers)
  let hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")
  let body = @buf.string_to_utf8_bytes("Hello").to_array()
  (StatusCode::OK, hs, body, false)
}

let rx = @buf.string_to_utf8_bytes("GET / HTTP/1.1\r\nHost: a\r\n\r\n").to_array()
let io = @tsp.from_inmemory(rx)
let _  = serve_once(io, hello, 32, 1024, 4096)
println(Bytes::from_array(io.take_tx()).to_string())
```

### 2) 保持连接的循环服务端

```moonbit
use http/http1 { serve_loop }
let _ = serve_loop(io, hello, 32, 1024, 4096)
```

### 3) 客户端 GET / POST

```moonbit
use http/http1 { get, post }

let limits : Limits = { max_headers: 32, max_line: 1024, read_win: 4096, max_body: 1*1024*1024 }
let resp = get(io, "/", "example.com", Map::new(), limits).unwrap()
println(resp.status.code)
println(Bytes::from_array(resp.body.unwrap_bytes()).to_string())

let body = @buf.string_to_utf8_bytes("{\"ok\":true}").to_array()
let resp2 = post(io, "/api", "example.com", body, "application/json", Map::new(), limits).unwrap()
println(resp2.status.code)
```

### 4) 读取分块编码响应（来自测试用例）

```moonbit
let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
          "5\r\nHello\r\n" ++
          "6\r\n World!\r\n" ++
          "0\r\n\r\n"
let io  = @tsp.from_inmemory(@buf.string_to_utf8_bytes(raw).to_array())
let resp = read_response(io, 32, 1024, 4096, 1024*1024).unwrap()
assert_eq!(Bytes::from_array(resp.body.unwrap_bytes()).to_string(), "Hello World!")
```

### 5) 处理 POST 请求体（来自测试用例）

```moonbit
let raw = "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nHello World"
let io  = @tsp.from_inmemory(@buf.string_to_utf8_bytes(raw).to_array())
let req = read_request_full(io, 32, 1024, 4096, 1024*1024).unwrap()
assert_eq!(req.line.method, "POST")
assert_eq!(Bytes::from_array(req.body.unwrap_bytes()).to_string(), "Hello World")
```

---

## API

### 解析器

```moonbit
fn parse_request_line(cur : @tsp.BufCursor) -> Result[@cor.RequestLine, String]
fn parse_headers(cur : @tsp.BufCursor, max_headers : Int, max_line : Int) -> Result[Map[String,String], String]
```

### 编码器

```moonbit
fn encode_status_line(status : @cor.StatusCode) -> String
fn encode_headers(headers : Map[String, String]) -> String
fn encode_content_length_prefix(content_length : Int) -> String
fn encode_chunked_bytes(body : Array[Byte], chunk_size : Int) -> Array[Byte]
fn encode_response_bytes(
  status : @cor.StatusCode,
  headers : Map[String, String],
  body : Array[Byte],
  is_chunked : Bool,
  chunk_size? : Int = 1024,
  content_length_override? : Int? = None
) -> Array[Byte]
```

### 服务端工具

```moonbit
fn read_request_full(io : @tsp.Transport, max_headers : Int, max_line : Int, read_win : Int, max_body : Int) -> Result[@cor.Request, String]
fn serve_once(io : @tsp.Transport, handler : (@cor.Request) -> (@cor.StatusCode, Map[String,String], Array[Byte], Bool), max_headers : Int, max_line : Int, read_win : Int, max_body? : Int = 1*1024*1024) -> Result[Unit, String]
fn serve_loop(io : @tsp.Transport, handler : (@cor.Request) -> (@cor.StatusCode, Map[String,String], Array[Byte], Bool), max_headers : Int, max_line : Int, read_win : Int, max_body? : Int = 1*1024*1024) -> Result[Unit, String]
```

### 客户端工具

```moonbit
fn read_response(io : @tsp.Transport, max_headers : Int, max_line : Int, read_win : Int, max_body : Int) -> Result[@cor.Response, String]
fn get(io : @tsp.Transport, target : String, host : String, extra_headers : Map[String, String], limits : @cor.Limits) -> Result[@cor.Response, String]
fn post(io : @tsp.Transport, target : String, host : String, body : Array[Byte], content_type : String, extra_headers : Map[String, String], limits : @cor.Limits) -> Result[@cor.Response, String]
```

---

## 注意事项

* **头部大小写不敏感**：内部会转换为小写进行查找。
* **限制项**：用于防御恶意输入：

  * `max_headers` — 头部最大数量
  * `max_line` — 单行最大长度
  * `read_win` — 每次读取的窗口大小
  * `max_body` — 消息体最大长度
* **分块编码**：支持响应的 chunked 编码/解码；请求端暂不支持 chunked 请求体。
* **状态码**：编码器默认支持 200/404/500，可通过 `core` 扩展。
* **传输层**：示例基于内存传输，可替换为真实后端。
* **错误语义**：

  * `WouldBlock` → 暂时无数据，可在推入新字节后重试。
  * `Eof` → 输入流结束，通常发生在 `close()` 后。
  * `Closed` → 在关闭后写入。
  * 这些语义直接来自传输层，方便与解析/客户端/服务端对接。

---

## 示例：分块响应处理

```moonbit
fn chunked(_req: Request) -> (StatusCode, Map[String,String], Array[Byte], Bool) {
  let hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")
  hs.set("Transfer-Encoding", "chunked")
  let body = @buf.string_to_utf8_bytes("hello, chunked!").to_array()
  (StatusCode::OK, hs, body, true)
}
```

---

## 路线图

* [ ] 支持请求端分块请求体 (`Transfer-Encoding: chunked`)
* [ ] 更多状态码映射
* [ ] 首部规范化与重复首部处理
* [ ] 非阻塞传输层适配（如 uv/epoll）

---

## 许可证

MIT License. 详见 [LICENSE](LICENSE)。
