# MoonbitHTTP/core （中文说明）

## 概览

MoonBit HTTP 项目的**核心数据结构层**，提供统一的请求/响应抽象。本包本身不涉及 I/O 或协议逻辑，仅定义：

* **请求行/响应行结构**
* **请求/响应整体结构**（头部、消息体）
* **状态码枚举**（200、404、500）
* **Body 类型**（空 / 字节数组）
* **限制参数 `Limits`**

这些类型是 `http/http1`、`http/transport` 等上层模块的基础依赖。

---

## 使用示例

### 构造一个 GET 请求

```moonbit
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

### 构造一个 200 OK 响应

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

### 请求/响应行

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

### 状态码

```moonbit
enum StatusCode {
  OK                  // 200
  NotFound            // 404
  InternalServerError // 500
}
```

### 消息体

```moonbit
enum Body {
  Empty
  Bytes(Array[Byte])
}
```

### 请求与响应

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

### 限制参数

```moonbit
struct Limits {
  max_headers : Int
  max_line    : Int
  read_win    : Int
  max_body    : Int
}
```

---

## 注意事项

* **扩展性**：状态码目前只包含 200/404/500，可按需扩展。
* **头部存储**：使用 `Map[String,String]`，调用方需自己处理大小写与合并策略。
* **Body**：若为 `Empty`，则不生成 `Content-Length`；若为 `Bytes`，则包含原始字节。
* **Limits**：防御性参数，用于限制头数量、行长度、消息体大小等。

---

## 示例：结合 http1 使用

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

## 许可证

MIT License. 详见 [LICENSE](LICENSE)。
