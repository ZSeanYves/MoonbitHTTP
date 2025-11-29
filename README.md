# ZSeanYves/MoonbitHTTP (English)

## Overview

**MoonbitHTTP** is a collection of HTTP protocol libraries for [MoonBit](https://www.moonbitlang.com/). It aims to be modular, test-friendly, and extensible.
It consists of several subpackages, each with its own README and API documentation:

* [`http/core`](./src/core/README.md): Core HTTP data structures (Request/Response, Status codes, Body, Limits)
* [`http/transport`](./src/transport/README.md): Lightweight in-memory transport and buffer cursor for testing and incremental parsing
* [`http/http1`](./src/http1/README.md): HTTP/1.1 codec (parsing & encoding, server/client helpers)
* [`http/http2`](./src/http2/README.md): HTTP/2 (planned / in development)

For detailed descriptions, usage examples, and APIs, please refer to each subpackage’s **README.md**.

---

## Features

* **Modular design**: Core, transport, HTTP/1.1, and HTTP/2 are decoupled
* **Test-friendly**: All modules can be tested fully in-memory without real networking (real networking planned later)
* **Progressive enhancement**: From simple `Content-Length` responses to `chunked`, then to HTTP/2 multiplexing
* **Ecosystem compatible**: Depends on utilities like [`bufferutils`](https://github.com/ZSeanYves/BufferUtils)

---

## Install

```bash
moon add ZSeanYves/MoonbitHTTP
```

Or edit `moon.mod.json`:

```json
"import": ["ZSeanYves/MoonbitHTTP"]
```

---

## Example

A minimal example: run a server with in-memory transport, parse a request, and send back a response.

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
//println(Bytes::from_array(io.take_tx()).to_string())
```

---

## Roadmap

* [x] `http/core`: Core types
* [x] `http/transport`: In-memory transport
* [x] `http/http1`: HTTP/1.1 support
* [ ] `http/http2`: HTTP/2 support

---

## License

MIT License. See [LICENSE](./LICENSE).
