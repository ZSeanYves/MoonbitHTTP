# MoonbitHTTP/core

## Overview

Core **data structures** for MoonBit HTTP projects, providing unified request/response abstractions. This package has **no I/O or protocol logic**; it only defines the basic types used by higher-level modules like `http/http1` and `http/transport`.

* **Request/Response line structs**
* **Request/Response containers** (headers, body)
* **Status codes** (200, 404, 500)
* **Body type** (Empty / Bytes)
* **Limits** for parsing/transport guards

---

## Usage

### Build a GET request

```moonbit
use http/core

let line = RequestLine {
  method: "GET",
  target: "/",
  version: "HTTP/1.1"
}

let headers : Map[String,String] = Map::new()
headers.set("Host", "example.com")

let req = Request {
  line: line,
  headers: headers,
  body: Body::Empty
}
```

### Build a 200 OK response

```moonbit
let status = StatusLine {
  version: "HTTP/1.1",
  code: StatusCode::OK
}

let hs : Map[String,String] = Map::new()
hs.set("Content-Type", "text/plain")

let resp = Response {
  status: status,
  headers: hs,
  body: Body::Bytes("Hello".to_utf8_array())
}
```

---

## API

### Request & Response Line

```moonbit
struct RequestLine {
  method  : String
  target  : String
  version : String
}

struct StatusLine {
  version : String
  code    : StatusCode
}
```

### Status Codes

```moonbit
enum StatusCode {
  OK                  // 200
  NotFound            // 404
  InternalServerError // 500
}
```

### Body

```moonbit
enum Body {
  Empty
  Bytes(Array[Byte])
}
```

### Request & Response

```moonbit
struct Request {
  line    : RequestLine
  headers : Map[String, String]
  body    : Body
}

struct Response {
  status  : StatusLine
  headers : Map[String, String]
  body    : Body
}
```

### Limits

```moonbit
struct Limits {
  max_headers : Int
  max_line    : Int
  read_win    : Int
  max_body    : Int
}
```

---

## Notes

* **Extensible**: status codes currently only include 200/404/500; extend as needed.
* **Headers**: stored as `Map[String,String]`; case normalization/merging is caller’s responsibility.
* **Body**: `Empty` means no content; `Bytes` carries raw payload.
* **Limits**: guard against malicious inputs, set by parsers/clients.

---

## Example with http1

```moonbit
use http/core
use http/http1 { encode_response_bytes }

let status = StatusLine { version: "HTTP/1.1", code: StatusCode::OK }
let hs : Map[String,String] = Map::new()
hs.set("Content-Type", "text/plain")

let body = "Hi".to_utf8_array()

let resp_bytes = encode_response_bytes(status.code, hs, body, false)
//println(Bytes::from_array(resp_bytes).to_string())
```

---

## License

MIT License. See [LICENSE](LICENSE).

---

