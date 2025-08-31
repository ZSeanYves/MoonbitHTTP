# http/http1

## Overview

A lightweight HTTP/1.1 toolkit for MoonBit that focuses on **incremental parsing** and **straightforward encoding**. It is transport‑agnostic and works perfectly with the in‑memory transport in `http/transport` for tests, then can be wired to a real backend later.

What you get:

* **Parser**: request line (`METHOD SP target SP HTTP/x.y`) and headers (CRLF‑terminated, with whitespace trimming).
* **Encoder**: status line + headers + body; supports **Content‑Length** or **chunked**.
* **Handler (one‑shot)**: ties transport, parser, and encoder together to handle a single request and write a response.

> Scope: this module does not yet parse request bodies. POST/`Content-Length` will be added next.

---

## Usage

### 1) End‑to‑end (read one request → handle → write response)

```moonbit
use @tsp = @ZSeanYves/MoonbitHTTP/transport
use @buf = @ZSeanYves/bufferutils
use http/http1 { serve_once, StatusCode }

// Minimal handler: always 200 text/plain
fn hello_handler(req : Request) -> (StatusCode, Map[String,String], Array[Byte], Bool) {
  ignore(req)
  let mut hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")
  let body = @buf.string_to_utf8_bytes("Hello, MoonBit!").to_array()
  (StatusCode::OK, hs, body, false) // non-chunked; encoder adds Content-Length
}

let io = @tsp.from_inmemory(@buf.string_to_utf8_bytes(
  "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
).to_array())

let _ = serve_once(io, hello_handler, /*max_headers*/64, /*max_line*/8*1024, /*read_win*/2048)

let out = io.take_tx()
println(Bytes::from_array(out).to_string())
```

### 2) Low‑level parsing: request line + headers

```moonbit
use @tsp = @ZSeanYves/MoonbitHTTP/transport
use @buf = @ZSeanYves/bufferutils
use http/http1 { parse_request_line, parse_headers }

let cur = @tsp.buf_new()
cur.buf_push(@buf.string_to_utf8_bytes("GET /index.html HTTP/1.1\r\n").to_array())
cur.buf_push(@buf.string_to_utf8_bytes("Host: example.com\r\n\r\n").to_array())

let rl = parse_request_line(cur).unwrap()    // { http_method, target, version }
let hs = parse_headers(cur, 64, 8*1024).unwrap()

println(Show::to_string(rl.http_method))     // "GET"
println(rl.target)                            // "/index.html"
println(hs.get("Host").unwrap_or(""))       // "example.com"
```

### 3) Encoding a response by hand

```moonbit
use http/http1 { encode_response, StatusCode }
use @buf = @ZSeanYves/bufferutils

let mut hs : Map[String,String] = Map::new()
hs.set("Content-Type", "text/plain")
let body = @buf.string_to_utf8_bytes("Hello").to_array()

// Non‑chunked: pass body.length() to emit Content-Length automatically
let resp = encode_response(StatusCode::OK, hs, body, body.length())
println(resp)

// Chunked: set TE header yourself and pass 0 as content_length
let mut hs2 : Map[String,String] = Map::new()
hs2.set("Content-Type", "text/plain")
hs2.set("Transfer-Encoding", "chunked")
let resp2 = encode_response(StatusCode::OK, hs2, body, 0)
println(resp2)
```

---

## API

### Parser

```moonbit
// Request method
enum Method { GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH, TRACE, CONNECT, Other(String) }

// Request line
struct RequestLine { http_method : Method, target : String, version : String }

// Parse one CRLF‑terminated line into RequestLine
fn parse_request_line(cur : @tsp.BufCursor) -> Result[RequestLine, String]

// Parse headers until a blank line; trims surrounding whitespace
fn parse_headers(cur : @tsp.BufCursor, max_headers : Int, max_line : Int)
  -> Result[Map[String,String], String]
```

### Encoder

```moonbit
enum StatusCode { OK = 200, NotFound = 404, InternalServerError = 500 }

// Build a complete HTTP/1.1 response text.
// If content_length > 0 → non‑chunked (adds Content-Length + CRLFCRLF + body)
// If content_length == 0 → chunked (requires caller to set TE header; emits one body chunk + 0\r\n\r\n)
fn encode_response(
  status : StatusCode,
  headers : Map[String,String],
  body : Array[Byte],
  content_length : Int
) -> String
```

### Handler (one‑shot)

```moonbit
struct Request { line : RequestLine, headers : Map[String,String] }

// Read a single request from transport, call user handler, write response.
// handler returns: (status, headers, body, is_chunked)
fn serve_once(
  io : @tsp.Transport,
  handler : (Request) -> (StatusCode, Map[String,String], Array[Byte], Bool),
  max_headers : Int,
  max_line : Int,
  read_win : Int
) -> Result[Unit, String]
```

---

## Notes

* Uses `bufferutils` for UTF‑8 conversion in examples: `@buf.string_to_utf8_bytes("...").to_array()`.
* Header map iteration order is not guaranteed; tests should assert presence instead of exact order.
* Current chunked encoding emits the whole body as **one chunk** (sufficient for tests). Chunk size formatting is decimal for now.
* Request bodies (e.g., `Content-Length`) are not parsed yet; coming next.
