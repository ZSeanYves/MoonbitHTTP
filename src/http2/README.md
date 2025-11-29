# MoonbitHTTP/http2

[![Build Status](https://img.shields.io/github/actions/workflow/status/ZSeanYves/MoonbitHTTP/ci.yml)](https://github.com/ZSeanYves/MoonbitHTTP/actions)
[![License](https://img.shields.io/github/license/ZSeanYves/MoonbitHTTP)](LICENSE)

## Overview

A **minimal HTTP/2 toolkit** for MoonBit: frame layer (9‑byte header + payload), **HEADERS/DATA framing helpers**, and a compact **HPACK** (static table + literal‑without‑index, optional Huffman). This package focuses on testability and clarity; it runs over an abstract transport (e.g., `@tsp.Transport`) and does not open real sockets.

**What you get**

* **Frames**: encode/decode the 9‑byte frame header; build and parse core frames: **SETTINGS**, **PING**, **GOAWAY**, **WINDOW_UPDATE**, **RST_STREAM**; read arbitrary frames from a transport.
* **HEADERS/DATA helpers**: split a header block into HEADERS + CONTINUATION with `END_HEADERS`; segment body bytes into DATA frames with `END_STREAM`.
* **HPACK**: static table lookups and **literal‑without‑index** encoding (names use static index when available); block decoder; optional Huffman encode/decode.
* **Preface & handshake**: client preface bytes; basic SETTINGS exchange helpers.

> Scope: geared for learning/tests. Dynamic table, priority scheduling, flow control bookkeeping, and HPACK indexing strategies beyond literal‑without‑index are intentionally minimal.

---

## Usage

### 1) Encode headers → HEADERS(+CONTINUATION) frames

```moonbit
use http/http2 { build_headers_frames_from_list }
use @buf = @ZSeanYves/bufferutils

let hs : Array[HpackHeader] = []
hs.push({ name: ":method",   value: "GET" })
hs.push({ name: ":scheme",   value: "https" })
hs.push({ name: ":authority", value: "example.com" })
hs.push({ name: ":path",      value: "/" })
hs.push({ name: "accept",     value: "*/*" })

// HPACK (literal-noindex) → HEADERS/CONTINUATION frames (auto-sliced)
let frames = build_headers_frames_from_list(1, hs, false)
```

### 2) Read HEADERS as a list of (name,value)

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

### 3) DATA frames

```moonbit
use http/http2 { build_data_frames }
let body = @buf.string_to_utf8_bytes("hello").to_array()
let data_frames = build_data_frames(1, body, true)
```

### 4) Preface + SETTINGS handshake

```moonbit
use http/http2 { h2_client_start, h2_server_accept_and_ack, H2SettingKV }
use @tsp = @ZSeanYves/MoonbitHTTP/transport
let io  = @tsp.from_inmemory([])
let cur = @tsp.buf_new()

// client side
let _ = h2_client_start(io, [])

// server side (reads preface and client SETTINGS, replies ACK)
let _ = h2_server_accept_and_ack(cur, io, 4096)
```

---

## API

### Constants & structs

```moonbit
// Frame types
pub const H2_FRAME_DATA          : Int = 0x0
pub const H2_FRAME_HEADERS       : Int = 0x1
pub const H2_FRAME_PRIORITY      : Int = 0x2
pub const H2_FRAME_RST_STREAM    : Int = 0x3
pub const H2_FRAME_SETTINGS      : Int = 0x4
pub const H2_FRAME_PUSH_PROMISE  : Int = 0x5
pub const H2_FRAME_PING          : Int = 0x6
pub const H2_FRAME_GOAWAY        : Int = 0x7
pub const H2_FRAME_WINDOW_UPDATE : Int = 0x8
pub const H2_FRAME_CONTINUATION  : Int = 0x9

// Flags (bit mask)
pub const H2_FLAGS_ACK         : Int = 0x1    // SETTINGS, PING
pub const H2_FLAGS_END_STREAM  : Int = 0x1    // DATA/HEADERS (same bit, context-dependent)
pub const H2_FLAGS_END_HEADERS : Int = 0x4
pub const H2_FLAGS_PADDED      : Int = 0x8
pub const H2_FLAGS_PRIORITY    : Int = 0x20

// Defaults & preface
pub const H2_DEFAULT_MAX_FRAME_SIZE : Int = 16384
pub const H2_CLIENT_PREFACE : String = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

// Core structs
pub struct H2FrameHeader { length : Int, typ : Int, flags : Int, stream_id : Int }
pub struct H2Frame       { header : H2FrameHeader, payload : Array[Byte] }
pub struct H2SettingKV   { id : Int, value : Int }
pub struct H2Priority    { exclusive : Bool, dep_stream : Int, weight : Int }
pub struct H2HeadersInfo { stream_id : Int, end_stream : Bool, has_priority : Bool, exclusive : Bool, dep_stream : Int, weight : Int }
pub struct HpackHeader   { name : String, value : String }
```

### Frame layer

```moonbit
fn encode_frame_header(h : H2FrameHeader) -> Array[Byte]
fn decode_frame_header(bs : Array[Byte]) -> Result[H2FrameHeader, String]
fn read_frame(cur : @tsp.BufCursor, io : @tsp.Transport, read_win : Int, max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE) -> Result[H2Frame, String]

fn client_preface_bytes() -> Array[Byte]
fn read_and_check_client_preface(cur : @tsp.BufCursor, io : @tsp.Transport, read_win : Int) -> Result[Unit, String]

fn encode_settings_payload(kvs : Array[H2SettingKV]) -> Array[Byte]
fn decode_settings_payload(bs : Array[Byte]) -> Result[Array[H2SettingKV], String]
fn build_settings_frame(kvs : Array[H2SettingKV], ack : Bool) -> Array[Byte]
fn parse_settings_frame(f : H2Frame) -> Result[(Bool, Array[H2SettingKV]), String]

fn build_ping_frame(opaque8 : Array[Byte], ack : Bool) -> Array[Byte]
fn parse_ping_frame(f : H2Frame) -> Result[(Bool, Array[Byte]), String]

fn build_goaway_frame(last_stream_id : Int, error_code : Int, debug : Array[Byte]) -> Array[Byte]

fn build_window_update_frame(stream_id : Int, increment : Int) -> Array[Byte]
fn parse_window_update_increment(f : H2Frame) -> Result[Int, String]

fn build_rst_stream_frame(stream_id : Int, error_code : Int) -> Array[Byte]
fn parse_rst_stream_error(f : H2Frame) -> Result[Int, String]

// Convenience
fn h2_client_start(io : @tsp.Transport, settings : Array[H2SettingKV]) -> Result[Unit, String]
fn h2_server_accept_and_ack(cur : @tsp.BufCursor, io : @tsp.Transport, read_win : Int, max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE) -> Result[Array[H2SettingKV], String]
```

### HEADERS / DATA helpers

```moonbit
fn read_headers_block(cur : @tsp.BufCursor, io : @tsp.Transport, read_win : Int, max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE) -> Result[(H2HeadersInfo, Array[Byte]), String]
fn read_headers_as_list(cur : @tsp.BufCursor, io : @tsp.Transport, read_win : Int, max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE) -> Result[(H2HeadersInfo, Array[HpackHeader]), String]

fn build_headers_frames(stream_id : Int, fragment : Array[Byte], end_stream : Bool, max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE) -> Array[Byte]
fn build_headers_frames_prio(stream_id : Int, fragment : Array[Byte], end_stream : Bool, exclusive : Bool, dep_stream : Int, weight : Int, max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE) -> Array[Byte]

fn build_data_frames(stream_id : Int, body : Array[Byte], end_stream : Bool, max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE) -> Array[Byte]
```

### HPACK

```moonbit
fn hpack_static_get(idx : Int) -> (String, String)?
fn hpack_encode_literal_noindex(name : String, value : String, use_huffman? : Bool = false) -> Array[Byte]
fn hpack_encode_list_noindex(hs : Array[HpackHeader]) -> Array[Byte]
fn hpack_decode_block(block : Array[Byte]) -> Result[Array[HpackHeader], String]
fn hpack_huff_encode(raw : Array[Byte]) -> Result[Array[Byte], String]
fn hpack_huff_decode(data : Array[Byte]) -> Result[Array[Byte], String]
```

---

## Notes

* **No dynamic table**: decoding returns error on dynamic table size updates; encoding uses *literal‑without‑index* and static name indexes.
* **Huffman**: optional on encode; decoder builds a small trie for bit‑level decode.
* **Padding & priority**: `build_headers_frames_prio` supports PRIORITY fields; explicit **PADDED** build is not provided yet.
* **Single‑stream examples**: examples assume `stream_id = 1` and do not implement full stream state machines.
* **Flow control**: helper to build/parse WINDOW_UPDATE exists, but global/per‑stream window bookkeeping is left to callers.
* **Errors / I/O**: APIs surface transport errors (`WouldBlock`, `Eof`, `Closed`) from the in‑memory transport layer; `read_win` controls incremental reads.

---

## Roadmap

* [ ] HPACK **dynamic table** (inserts/eviction) and more header representations
* [ ] Full header padding and trailer handling
* [ ] Stream state machine, PRIORITY scheduling, server push
* [ ] Flow‑control windows management (connection + per‑stream)
* [ ] End‑to‑end client/server examples beyond the "hello" demo

---

## License

MIT License. See [LICENSE](LICENSE).

---

