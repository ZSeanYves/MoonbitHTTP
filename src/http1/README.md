# MoonbitHTTP/http1

[![Build Status](https://img.shields.io/github/actions/workflow/status/ZSeanYves/MoonbitHTTP/ci.yml)](https://github.com/ZSeanYves/MoonbitHTTP/actions)
[![License](https://img.shields.io/github/license/ZSeanYves/MoonbitHTTP)](LICENSE)

## Overview

A modular, test-friendly **HTTP/1.1 library** for MoonBit projects. Provides parsing, encoding, and minimal client/server helpers, built on top of a pluggable transport layer (e.g., [`MoonbitHTTP/transport`](../transport)).

* **Parser**: read request lines, headers, and bodies incrementally.
* **Encoder**: build responses with `Content-Length` or `chunked` transfer encoding.
* **Server helpers**: `serve_once` and `serve_loop` to wire transport, parser, and encoder together.
* **Client helpers**: `get`, `post`, `read_response` for simple HTTP/1.1 interaction.

This package is **protocol logic only** (no real networking). Designed for clean unit tests and easy extension.

---

## Usage

### 1) Minimal server: one request → one response

```moonbit
use @tsp = @ZSeanYves/MoonbitHTTP/transport
use @buf = @ZSeanYves/bufferutils
use http/http1 { serve_once, StatusCode }

fn hello(req: Request) -> (StatusCode, Map[String,String], Array[Byte], Bool) {
  //println("req line = {}", req.line)
  //println("headers = {:?}", req.headers)
  let hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")
  let body = @buf.string_to_utf8_bytes("Hello").to_array()
  (StatusCode::OK, hs, body, false)
}

let rx = @buf.string_to_utf8_bytes("GET / HTTP/1.1\r\nHost: a\r\n\r\n").to_array()
let io = @tsp.from_inmemory(rx)
let _  = serve_once(io, hello, 32, 1024, 4096)
//println(Bytes::from_array(io.take_tx()).to_string())
```

### 2) Keep-alive server loop

```moonbit
use http/http1 { serve_loop }
let _ = serve_loop(io, hello, 32, 1024, 4096)
```

### 3) Client GET / POST

```moonbit
use http/http1 { get, post }

let limits : Limits = { max_headers: 32, max_line: 1024, read_win: 4096, max_body: 1*1024*1024 }
let resp = get(io, "/", "example.com", Map::new(), limits).unwrap()
//println(resp.status.code)
//println(Bytes::from_array(resp.body.unwrap_bytes()).to_string())

let body = @buf.string_to_utf8_bytes("{\"ok\":true}").to_array()
let resp2 = post(io, "/api", "example.com", body, "application/json", Map::new(), limits).unwrap()
//println(resp2.status.code)
```

### 4) Reading chunked response (from tests)

```moonbit
let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
          "5\r\nHello\r\n" ++
          "6\r\n World!\r\n" ++
          "0\r\n\r\n"
let io  = @tsp.from_inmemory(@buf.string_to_utf8_bytes(raw).to_array())
let resp = read_response(io, 32, 1024, 4096, 1024*1024).unwrap()
assert_eq!(Bytes::from_array(resp.body.unwrap_bytes()).to_string(), "Hello World!")
```

### 5) Handling POST request body (from tests)

```moonbit
let raw = "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nHello World"
let io  = @tsp.from_inmemory(@buf.string_to_utf8_bytes(raw).to_array())
let req = read_request_full(io, 32, 1024, 4096, 1024*1024).unwrap()
assert_eq!(req.line.method, "POST")
assert_eq!(Bytes::from_array(req.body.unwrap_bytes()).to_string(), "Hello World")
```

---

## API

### Parser

```moonbit
fn parse_request_line(cur : @tsp.BufCursor) -> Result[@cor.RequestLine, String]
fn parse_headers(cur : @tsp.BufCursor, max_headers : Int, max_line : Int) -> Result[Map[String,String], String]
```

### Encoder

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

### Server helpers

```moonbit
fn read_request_full(io : @tsp.Transport, max_headers : Int, max_line : Int, read_win : Int, max_body : Int) -> Result[@cor.Request, String]
fn serve_once(io : @tsp.Transport, handler : (@cor.Request) -> (@cor.StatusCode, Map[String,String], Array[Byte], Bool), max_headers : Int, max_line : Int, read_win : Int, max_body? : Int = 1*1024*1024) -> Result[Unit, String]
fn serve_loop(io : @tsp.Transport, handler : (@cor.Request) -> (@cor.StatusCode, Map[String,String], Array[Byte], Bool), max_headers : Int, max_line : Int, read_win : Int, max_body? : Int = 1*1024*1024) -> Result[Unit, String]
```

### Client helpers

```moonbit
fn read_response(io : @tsp.Transport, max_headers : Int, max_line : Int, read_win : Int, max_body : Int) -> Result[@cor.Response, String]
fn get(io : @tsp.Transport, target : String, host : String, extra_headers : Map[String, String], limits : @cor.Limits) -> Result[@cor.Response, String]
fn post(io : @tsp.Transport, target : String, host : String, body : Array[Byte], content_type : String, extra_headers : Map[String, String], limits : @cor.Limits) -> Result[@cor.Response, String]
```

---

## Notes

* **Case-insensitive headers**: internally normalized to lowercase for lookup.
* **Limits**: guard rails against malicious input:

  * `max_headers` — maximum number of headers
  * `max_line` — maximum line length
  * `read_win` — per-read window size
  * `max_body` — maximum body size
* **Chunked encoding**: supported on response encode/decode; request-side chunked body **not yet supported**.
* **Status codes**: encoder includes 200/404/500 defaults; extend via `core` as needed.
* **Transport**: examples assume in-memory transport; swap in real backend later.
* **Error semantics**:

  * `WouldBlock` → temporarily no data, caller may retry after pushing new bytes.
  * `Eof` → end-of-stream, usually after `close()`.
  * `Closed` → writing after transport closed.
  * These mirror the transport layer to integrate cleanly with parser/client/server.

---

## Example: chunked response handler

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

## Roadmap

* [ ] Support chunked request bodies (`Transfer-Encoding: chunked` on requests)
* [ ] More complete status code mappings
* [ ] Header canonicalization and duplicate header handling
* [ ] Non-blocking transport backends (e.g., uv/epoll adapters)

---

## License

MIT License. See [LICENSE](LICENSE).
