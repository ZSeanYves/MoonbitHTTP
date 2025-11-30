# MoonbitHTTP — HTTP/2 模块

> 对应 `src/http2` 的中文版 README

## 1. 模块概览

MoonbitHTTP 的 **`http2` 模块**提供的是 **HTTP/2 协议的帧层实现 + HPACK 头部压缩实现**，重点在于：

* 正确解析 / 编码各类 HTTP/2 **帧（Frame）**
* 识别并处理 HTTP/2 **连接前言（Connection Preface）**
* 实现 **HPACK 静态表** 的头部压缩与解压
* 对协议违规进行清晰的错误报告和校验

它目前 **不是** 一个完整的 HTTP/2 服务端或客户端实现：

* ❌ 不实现流量控制（Flow Control）
* ❌ 不实现优先级 / Server Push

更适合用于：

* 学习 / 调试 HTTP/2 二进制层细节
* 搭建自定义的 HTTP/2 工具（例如抓包分析器、测试工具、代理等）
* 为未来的高层 HTTP/2 Runtime（真正的服务端 / 客户端）打基础

如果你只需要 HTTP/1.1，可以查看 [`src/http1`](../http1/README.md)。

---

## 2. 设计目标

* **关注点分离**：`http2` 只关心 *帧* 和 *HPACK*，不负责连接管理、路由或业务逻辑
* **方便测试**：所有 API 都可以在内存中运行，依赖共享的 `transport` 模块（无需真实网络）
* **显式控制**：连接、流状态、SETTINGS、流量控制等都交给调用者管理
* **术语贴近 RFC**：命名尽量与 HTTP/2 标准（RFC 7540）保持一致

当前的非目标：

* 不内置完整 HTTP/2 服务器或客户端
* 不自动管理流量控制窗口
* 不实现 Server Push 与复杂优先级调度

---

## 3. 包结构（逻辑划分）

典型结构（文件名可能略有差异，仅作逻辑说明）：

* `http2/preface.mbt`

  * 识别 / 校验 HTTP/2 客户端和服务端前言（Preface）的工具函数
* `http2/frame.mbt`

  * 核心帧类型（DATA/HEADERS/SETTINGS/...）与编码 / 解码逻辑
* `http2/hpack.mbt`

  * HPACK 静态表与头部块（Header Block）的压缩 / 解压
* `http2/error.mbt`

  * HTTP/2 专用错误枚举与辅助函数

实际使用时，你通常不会一次性 import 所有模块，而是按需选用：

```moonbit
use http/http2/preface { detect_client_preface }
use http/http2/frame   { decode_frame, encode_settings_frame }
use http/http2/hpack   { hpack_encode, hpack_decode }
```

> 注意：具体文件名在项目演进中可能略有调整，但“前言 / 帧 / HPACK”的划分会保持稳定。

---

## 4. 已实现的 HTTP/2 功能

### 4.1 连接前言（Connection Preface）

* `detect_client_preface(bytes: Array[Byte]) -> Bool`

  * 判断字节序列是否以固定的 HTTP/2 客户端前言开头：
    `"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"`
* 可选：`detect_server_preface` 用于校验服务端发出的第一个帧 / 首个响应序列是否合理

通常在 **连接入口** 就会使用这些工具，来区分：

* 这是发来的 HTTP/1.1 请求？
* 还是 HTTP/2 前言？

### 4.2 帧编解码（Frame Codec）

`frame` 模块提供：

* 一个统一的 `Frame` 枚举类型，内部包含所有具体帧类型的变体
* 每种帧的独立编码 / 解码函数

支持的帧类型包括（按 HTTP/2 标准）：

* `DATA`
* `HEADERS`
* `PRIORITY`
* `RST_STREAM`
* `SETTINGS`
* `PUSH_PROMISE`（可以解析，目前不会在 Runtime 中主动使用）
* `PING`
* `GOAWAY`
* `WINDOW_UPDATE`

**解码示例**：

```moonbit
use http/http2/frame { decode_frame, Frame }
use @tsp = @ZSeanYves/MoonbitHTTP/transport

let raw : Array[Byte] = [
  0, 0, 4,    // length = 4
  0x4, 0x0,   // type = SETTINGS, flags = 0
  0, 0, 0, 0  // stream_id = 0
]

let io  = @tsp.from_inmemory(raw)
let f   = decode_frame(io).unwrap()

match f {
| Frame::Settings(s) => {
    // 处理 SETTINGS
  }
| _ => {
    // 处理其他类型帧
  }
}
```

**编码示例：SETTINGS 帧**：

```moonbit
use http/http2/frame { encode_settings_frame, SettingPair }

let settings : Array[SettingPair] = [
  { id: 0x1, value: 4096 }, // HEADER_TABLE_SIZE
  { id: 0x3, value: 100 },  // MAX_CONCURRENT_STREAMS
]

let bytes = encode_settings_frame(settings, false)
// 将 bytes 通过你的 Transport 发送出去
```

其他帧类型也有类似的编码函数，例如：

* `encode_data_frame(stream_id, payload, end_stream)`
* `encode_headers_frame(stream_id, header_block, end_headers)`
* `encode_ping(ping_bytes, ack)`
* `encode_goaway(last_stream_id, error_code, debug_data)`
* `encode_window_update(stream_id, increment)`

> 具体函数签名可能略有差异，但核心目标只有一个：**构造出一帧合法的 HTTP/2 帧字节序列**。

### 4.3 HPACK（静态表）

`hpack` 模块实现 HPACK 编解码，用于压缩 / 解压 HEADERS 帧中携带的 Header Block：

* `hpack_encode(headers: Array[(String, String)]) -> Array[Byte]`
* `hpack_decode(bytes: Array[Byte]) -> Array[(String, String)]`

当前实现特点：

* 仅使用 HPACK 规范中的 **静态表（Static Table）**
* 支持 **“不入表的字面量头部”** 形式
* 当收到修改动态表大小的指令时会报错（即不支持动态表）

**解码示例**：

```moonbit
use http/http2/hpack { hpack_decode }
use @buf = @ZSeanYves/bufferutils

let encoded = @buf.string_to_utf8_bytes("\x82\x86\x84").to_array()
let headers = hpack_decode(encoded)
// headers : Array[(String, String)]
```

**编码示例**：

```moonbit
use http/http2/hpack { hpack_encode }

let headers : Array[(String, String)] = [
  (":method", "GET"),
  ("host", "example.com"),
]

let encoded_block = hpack_encode(headers)
// `encoded_block` 可作为 HEADERS 帧中的头部块
```

---

## 5. 综合示例：构造一个简单的帧“查看器”

下面是一个将各组件组合起来的示例：从一个 `Transport` 中读取数据，识别 HTTP/2 前言，并循环解析帧，打印或处理：

```moonbit
use http/http2/preface { detect_client_preface }
use http/http2/frame   { decode_frame, Frame }
use @tsp = @ZSeanYves/MoonbitHTTP/transport

fn inspect_connection(rx: Array[Byte]) {
  let io = @tsp.from_inmemory(rx)

  // 例如先窥探前 N 字节，不消费
  let preface_bytes = io.peek(24)
  if !detect_client_preface(preface_bytes) {
    // 不是 HTTP/2（可能是 HTTP/1.1 或垃圾数据）
    return
  }

  // 正式消费前言（具体做法依具体 Transport 实现）
  let _ = io.consume(preface_bytes.length())

  // 不断读取帧
  loop {
    match decode_frame(io) {
    | Err(e) => {
        // EOF 或协议错误，直接退出
        break
      }
    | Ok(f) => {
        match f {
        | Frame::Settings(s) => {
            // 打印 / 应用 SETTINGS
          }
        | Frame::Data(d) => {
            // 检查 Data 内容
          }
        | Frame::Headers(h) => {
            // 需要的话，可以再调用 hpack_decode 解出头部
          }
        | _ => {
            // 其他帧
          }
        }
      }
    }
  }
}
```

> 这个示例故意保持“低抽象”，所以连接何时结束、何时回 SETTINGS、如何维护状态，全部交给调用者决定。

---

## 6. 与其它模块的关系

在未来构建完整 HTTP 栈时，你大致会这样分层：

* `transport` —— 内存 / 真实网络 IO
* `http2` —— 帧、HPACK、前言检测
* （未来）`http2_runtime` —— 流状态机、流量控制、请求/响应映射
* `core` —— 通用的 `Request`、`Response`、`StatusCode`、`Body`、`Limits` 等

目前 `http2` 有意停在“帧 + HPACK”层，以保持：

* 实验安全（不会隐藏复杂的 Runtime 副作用）
* 方便单元测试
* 允许用户在其上自定义不同风格的 Runtime（服务器、代理、隧道工具等）

---

## 7. 当前限制与非目标

* ❌ 暂无开箱即用的 HTTP/2 服务器 / 客户端
* ❌ 不会自动发送 / 处理 SETTINGS + ACK
* ❌ 不跟踪连接 / 流的窗口大小（Flow Control）
* ❌ 不实现优先级 / 依赖树
* ❌ 不支持 Server Push
* ❌ 不包含 TLS / ALPN 协商
* ❌ 不包含 HTTP/1.1 ↔ HTTP/2 Upgrade 逻辑

这些都更适合作为“上层 Runtime”的职责，而不是 `http2` 模块本身的职责。

---

## 8. Roadmap（后续计划）

计划中的演进方向（可能随实际开发调整）：

* [ ] 基础版 HTTP/2 Runtime（单连接，有限流数）
* [ ] 连接级和流级的流量控制管理
* [ ] HPACK 动态表与压缩策略调优
* [ ] 多路复用工具函数，以及简单的请求/响应映射
* [ ] 与 HTTP/1.1 的自动协商 / 升级辅助函数

在这些内容完成之前，请将 `http2` 看作一个 **低层协议工具箱**，而不是一个“框架接口”。

---

## 9. 许可证

与整个 MoonbitHTTP 项目一致，本模块使用 **MIT 许可证**。
