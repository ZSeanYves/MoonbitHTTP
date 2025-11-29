# MoonbitHTTP/http2（中文说明）

## 概览

一个面向 MoonBit 的 **HTTP/2 工具包**：提供帧层（9 字节帧头 + 载荷）、**HEADERS/DATA 构帧工具**，以及精简的 **HPACK**（静态表 + 非索引字面量，可选 Huffman）。本包侧重教学与测试，运行在抽象传输层（如 `@tsp.Transport`）之上，不直接进行真实网络通信。

**你将获得**：

* **帧层 API**：编码/解码帧头；构造与解析核心帧：**SETTINGS**、**PING**、**GOAWAY**、**WINDOW_UPDATE**、**RST_STREAM**；从传输层读取任意帧。
* **HEADERS/DATA 工具**：把头块切分为 HEADERS + CONTINUATION（自动设置 `END_HEADERS`）；把消息体切分为 DATA 帧（可带 `END_STREAM`）。
* **HPACK**：静态表查询与**非索引字面量**编码（名称可用静态索引）；头块解码；可选 Huffman 编解码。
* **前言与握手**：客户端前言字节；SETTINGS 基本交换辅助函数。

> 范围说明：更偏向学习/测试用途。动态表、优先级调度、流量控制记账，以及更复杂的 HPACK 索引策略暂时保持最小化实现。

---

## 使用示例

### 1) HPACK 头列表 → HEADERS(+CONTINUATION) 帧

```moonbit
use http/http2 { build_headers_frames_from_list }
use @buf = @ZSeanYves/bufferutils

let hs : Array[HpackHeader] = []
hs.push({ name: ":method",   value: "GET" })
hs.push({ name: ":scheme",   value: "https" })
hs.push({ name: ":authority", value: "example.com" })
hs.push({ name: ":path",      value: "/" })
hs.push({ name: "accept",     value: "*/*" })

let frames = build_headers_frames_from_list(1, hs, false)
```

### 2) 读取 HEADERS 为 (name,value) 列表

```moonbit
use http/http2 { read_headers_as_list }
use @tsp = @ZSeanYves/MoonbitHTTP/transport

let io  = @tsp.from_inmemory(frames)
let cur = @tsp.buf_new()
let (info, list) = read_headers_as_list(cur, io, 4096).unwrap()
//println(info.stream_id)   // 1
//println(info.end_stream)  // false
//println(list[0].name)     // ":method"
```

### 3) DATA 帧

```moonbit
use http/http2 { build_data_frames }
let body = @buf.string_to_utf8_bytes("hello").to_array()
let data_frames = build_data_frames(1, body, true)
```

### 4) 前言 + SETTINGS 握手

```moonbit
use http/http2 { h2_client_start, h2_server_accept_and_ack, H2SettingKV }
use @tsp = @ZSeanYves/MoonbitHTTP/transport
let io  = @tsp.from_inmemory([])
let cur = @tsp.buf_new()

// 客户端：发送前言与 SETTINGS
let _ = h2_client_start(io, [])

// 服务端：读取前言与 SETTINGS，并回 ACK
let _ = h2_server_accept_and_ack(cur, io, 4096)
```

---

## API 速览

### 常量与结构体

```moonbit
// 帧类型与标志位、默认值、前言字符串
H2_FRAME_*、H2_FLAGS_*、H2_DEFAULT_MAX_FRAME_SIZE、H2_CLIENT_PREFACE

// 关键结构\ nH2FrameHeader { length, typ, flags, stream_id }
H2Frame { header, payload }
H2SettingKV { id, value }
H2Priority { exclusive, dep_stream, weight }
H2HeadersInfo { stream_id, end_stream, has_priority, exclusive, dep_stream, weight }
HpackHeader { name, value }
```

### 帧层

```moonbit
encode_frame_header / decode_frame_header
read_frame(cur, io, read_win, max_frame_size?)
client_preface_bytes / read_and_check_client_preface
encode_settings_payload / decode_settings_payload
build_settings_frame / parse_settings_frame
build_ping_frame / parse_ping_frame
build_goaway_frame
build_window_update_frame / parse_window_update_increment
build_rst_stream_frame / parse_rst_stream_error
h2_client_start / h2_server_accept_and_ack
```

### HEADERS / DATA

```moonbit
read_headers_block / read_headers_as_list
build_headers_frames / build_headers_frames_prio
build_data_frames
```

### HPACK

```moonbit
hpack_static_get
hpack_encode_literal_noindex / hpack_encode_list_noindex
hpack_decode_block
hpack_huff_encode / hpack_huff_decode
```

---

## 注意事项

* **无动态表**：遇到动态表大小更新会报错；编码只用非索引字面量与静态表名索引。
* **Huffman**：编码可选；解码通过小型解码树逐位处理。
* **填充与优先级**：提供 PRIORITY 版本构帧；**暂未**提供显式 PADDED 构帧。
* **单流示例**：文档示例默认使用 `stream_id = 1`，未实现完整流状态机。
* **流控**：提供 WINDOW_UPDATE 的编解码；窗口值管理交由调用方。
* **错误与 I/O**：会透传传输层错误（`WouldBlock`/`Eof`/`Closed`）；`read_win` 控制增量读取。

---

## 路线图

* [ ] HPACK **动态表** 与更多表述格式
* [ ] 完整的头部填充与 trailer 处理
* [ ] 流状态机、优先级调度、服务器推送
* [ ] 连接级与流级的流量控制记账
* [ ] 更完善的端到端示例（超越 "hello" demo）

---

## 许可证

MIT License. 详见 [LICENSE](LICENSE)。
