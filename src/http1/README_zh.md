# MoonbitHTTP/http1

[![Build Status](https://img.shields.io/github/actions/workflow/status/ZSeanYves/MoonbitHTTP/ci.yml)](https://github.com/ZSeanYves/MoonbitHTTP/actions)
[![License](https://img.shields.io/github/license/ZSeanYves/MoonbitHTTP)](LICENSE)


## 简介

MoonbitHTTP 的 HTTP/1.1 模块是一个**模块化、可测试、可扩展**的协议库，实现了 HTTP/1.1 的常见功能：请求解析、响应编码、客户端与服务端工具，并且 **完整支持流式（chunked）消息体**。

本模块只包含协议逻辑，不包含实际网络通信，可与任何传输层组合，并适用于单元测试场景。

---

## 功能特性

* ✔ **HTTP/1.1 请求解析**（请求行、头部、消息体）
* ✔ **HTTP/1.1 响应编码**（状态行、头部、消息体）
* ✔ **轻量客户端工具**：GET / POST
* ✔ **轻量服务端工具**：一次请求、循环服务、流式服务
* ✔ **完整流式支持**：

  * chunked 请求体解析
  * chunked 响应体编码
* ✔ **可插拔传输层**（如内存传输、Socket 适配器等）
* ✔ 支持安全限制（headers 限制、最大 body 限制等）

---

## 使用示例

### 1. 最小服务端示例

```moonbit
use @tsp = @ZSeanYves/MoonbitHTTP/transport
use @buf = @ZSeanYves/bufferutils
use http/http1 { serve_once, StatusCode }

fn hello(req: Request) -> (StatusCode, Map[String,String], Array[Byte], Bool) {
  let hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")
  let body = @buf.string_to_utf8_bytes("Hello").to_array()
  (StatusCode::OK, hs, body, false)
}

let raw = "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
let rx = @buf.string_to_utf8_bytes(raw).to_array()
let io = @tsp.from_inmemory(rx)
let _  = serve_once(io, hello, 32, 1024, 4096)
```

---

### 2. 循环服务端（支持 Keep-Alive）

```moonbit
use http/http1 { serve_loop }
let _ = serve_loop(io, hello, 32, 1024, 4096)
```

---

### 3. 客户端 GET / POST 示例

```moonbit
use http/http1 { get, post }

let limits : Limits = {
  max_headers: 32,
  max_line: 1024,
  read_win: 4096,
  max_body: 1*1024*1024,
}

let resp = get(io, "/", "example.com", Map::new(), limits).unwrap()
```

POST 示例：

```moonbit
let body = @buf.string_to_utf8_bytes("{\"ok\":true}").to_array()
let resp2 = post(io, "/api", "example.com", body, "application/json", Map::new(), limits).unwrap()
```

---

### 4. 读取 Chunked（分块传输）响应

```moonbit
let raw = "HTTP/1.1 200 OK\r\n" ++
          "Transfer-Encoding: chunked\r\n\r\n" ++
          "5\r\nHello\r\n" ++
          "6\r\n World!\r\n" ++
          "0\r\n\r\n"

let io  = @tsp.from_inmemory(@buf.string_to_utf8_bytes(raw).to_array())
let resp = read_response(io, 32, 1024, 4096, 1024*1024).unwrap()
```

---

### 5. 流式响应（Chunked，新增）

```moonbit
fn stream_resp(_req: Request) -> (StatusCode, Map[String,String], Body, Bool) {
  let hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")
  hs.set("Transfer-Encoding", "chunked")

  let parts : Array[String] = ["part1\n", "part2\n", "part3\n"]
  let mut i = 0

  let body = Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
    if i >= parts.length() {
      Ok(([], true))
    } else {
      let chunk = @buf.string_to_utf8_bytes(parts[i]).to_array()
      i += 1
      Ok((chunk, i >= parts.length()))
    }
  })

  (StatusCode::OK, hs, body, true)
}
```

调用：

```moonbit
let _ = serve_once_body_streaming(io, stream_resp, 32, 1024, 4096)
```

---

### 6. 流式回显 Chunked 请求体

```moonbit
let raw_req = "POST /echo HTTP/1.1\r\n" ++
              "Host: x\r\n" ++
              "Transfer-Encoding: chunked\r\n\r\n" ++
              "5\r\nHello\r\n" ++
              "0\r\n\r\n"

let io = @tsp.from_inmemory(@buf.string_to_utf8_bytes(raw_req).to_array())
let _  = serve_once_body_streaming(io, echo_handler_streaming, 32, 1024, 4096)
```

---

## API 速览

### 解析（Parsing）

* `parse_request_line`
* `parse_headers`
* `read_request_full`
* `read_request_streaming`

### 编码（Encoding）

* `encode_status_line`
* `encode_headers`
* `encode_response_bytes`
* `encode_chunked_bytes`

### 服务端（Server）

* `serve_once`
* `serve_loop`
* `serve_once_body`
* `serve_once_body_streaming`
* `write_response_with_body`

### 客户端（Client）

* `read_response`
* `get`
* `post`

---

## 注意事项

* **头部大小写不敏感**（内部转换为小写）
* **限制项（Limits）**用于防御恶意或超大输入
* **流式支持**包括 chunked 请求与 chunked 响应
* 可与任意传输层结合（内存、网络等）

---

## 未来计划（Roadmap）

* ✔ 支持 chunked 请求体解析
* ✔ 支持 chunked 响应流式输出
* ⏳ 更丰富的状态码支持
* ⏳ Header 规范化（Canonicalization）
* ⏳ 非阻塞传输层适配（uv/epoll）

---

## 许可证

MIT License
