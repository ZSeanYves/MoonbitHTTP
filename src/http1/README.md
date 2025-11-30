# MoonbitHTTP/http1

[![Build Status](https://img.shields.io/github/actions/workflow/status/ZSeanYves/MoonbitHTTP/ci.yml)](https://github.com/ZSeanYves/MoonbitHTTP/actions)
[![License](https://img.shields.io/github/license/ZSeanYves/MoonbitHTTP)](LICENSE)


A modular, test-friendly HTTP/1.1 protocol implementation for MoonBit. Includes parsing, encoding, client/server helpers, and full streaming support for both chunked requests and responses.

### Features

* HTTP/1.1 request parsing
* Response encoding
* Minimal client/server utilities
* Streaming bodies (chunked request + chunked response)
* Pluggable transport layer

---

## Usage Examples

### 1. Minimal Server

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

let rx = @buf.string_to_utf8_bytes("GET / HTTP/1.1\r\nHost: a\r\n\r\n").to_array()
let io = @tsp.from_inmemory(rx)
let _  = serve_once(io, hello, 32, 1024, 4096)
```

### 2. Server Loop

```moonbit
use http/http1 { serve_loop }
let _ = serve_loop(io, hello, 32, 1024, 4096)
```

### 3. Client GET/POST

```moonbit
use http/http1 { get, post }

let limits : Limits = { max_headers: 32, max_line: 1024, read_win: 4096, max_body: 1*1024*1024 }
let resp = get(io, "/", "example.com", Map::new(), limits).unwrap()
```

POST:

```moonbit
let body = @buf.string_to_utf8_bytes("{\"ok\":true}").to_array()
let resp2 = post(io, "/api", "example.com", body, "application/json", Map::new(), limits).unwrap()
```

### 4. Read Chunked Response

```moonbit
let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
          "5\r\nHello\r\n6\r\n World!\r\n0\r\n\r\n"
let io  = @tsp.from_inmemory(@buf.string_to_utf8_bytes(raw).to_array())
let resp = read_response(io, 32, 1024, 4096, 1024*1024).unwrap()
```

### 5. Streaming Response (NEW)

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

### 6. Streaming Request Echo

```moonbit
let raw_req = "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
              "5\r\nHello\r\n0\r\n\r\n"
let io = @tsp.from_inmemory(@buf.string_to_utf8_bytes(raw_req).to_array())
let _  = serve_once_body_streaming(io, echo_handler_streaming, 32, 1024, 4096)
```

---

## API Reference

* Parsing: request line, headers, full body, streaming body
* Encoding: headers, status line, content-length, chunked
* Server: serve_once, serve_loop, streaming handlers
* Client: get, post, read_response

---

## License

MIT License


