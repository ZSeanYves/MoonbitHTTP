# MoonbitHTTP/http2

[![Build Status](https://img.shields.io/github/actions/workflow/status/ZSeanYves/MoonbitHTTP/ci.yml)](https://github.com/ZSeanYves/MoonbitHTTP/actions)
[![License](https://img.shields.io/github/license/ZSeanYves/MoonbitHTTP)](LICENSE)


## 1. Overview

The **`http2`** package in MoonbitHTTP provides a **frame-level** and **HPACK-level** implementation of the HTTP/2 protocol.

It focuses on:

* Correct parsing / encoding of HTTP/2 **frames**
* Basic handling of the HTTP/2 **connection preface**
* Implementation of **HPACK static-table** header compression / decompression
* Clear error reporting and validation of protocol invariants

It is intentionally **not** a full HTTP/2 runtime.
There is **flow control, or prioritization** yet. Instead, this package acts as a **building block** for:

* Learning and debugging HTTP/2 at the binary level
* Building custom HTTP/2 tools (debuggers, inspectors, test harnesses)
* Providing the foundation for a future high-level HTTP/2 server/client

If you need an HTTP/1.1-only server/client, see [`src/http1`](../http1/README.md).

---

## 2. Design Goals

* **Separation of concerns**: This package only deals with *frames* and *HPACK*.
* **Testability**: All APIs work with in-memory buffers and the shared `transport` module (no real sockets required).
* **Explicitness over magic**: Callers are expected to explicitly manage connection / stream state, settings, and flow control.
* **Low surprise**: Function names and data structures follow the HTTP/2 RFC 7540 terminology as closely as possible.

Non-goals (for now):

* Implementing a full HTTP/2 server or client
* Managing flow control windows
* Implementing server push or priority scheduling

---

## 3. Package Layout

The typical layout looks like this (names simplified):

* `http2/preface.mbt`

  * Utilities to detect / validate HTTP/2 client and server prefaces
* `http2/frame.mbt`

  * Core frame types (DATA/HEADERS/SETTINGS/...) and encode/decode logic
* `http2/hpack.mbt`

  * HPACK static-table handling and header block (de)compression
* `http2/error.mbt`

  * HTTP/2 specific error enums and helpers

You normally do **not** import all of these directly from application code.
Instead, you selectively use the pieces you need, e.g.:

```moonbit
use http/http2/preface { detect_client_preface }
use http/http2/frame    { decode_frame, encode_settings_frame }
use http/http2/hpack    { hpack_encode, hpack_decode }
```

> Note: Exact file names may evolve, but the logical split (preface / frame / hpack) will remain stable.

---

## 4. Implemented HTTP/2 Features

### 4.1 Connection Preface

* `detect_client_preface(bytes: Array[Byte]) -> Bool`

  * Returns `true` if the byte sequence starts with the fixed HTTP/2 client preface:
    `"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"`
* Optionally, a `detect_server_preface` helper can be provided to validate the first frame(s) the server sends back.

These helpers are typically used at the **connection entry point** to decide whether the peer is attempting HTTP/1.1 or HTTP/2.

### 4.2 Frame Codec

The `frame` module provides:

* A common `Frame` sum type (variant/enum) that wraps all concrete frame kinds
* Per-frame encode/decode helpers

Supported frame types include (as separate constructors / variants):

* `DATA`
* `HEADERS`
* `PRIORITY`
* `RST_STREAM`
* `SETTINGS`
* `PUSH_PROMISE` (parsed, but not used at runtime yet)
* `PING`
* `GOAWAY`
* `WINDOW_UPDATE`

**Decoding**:

```moonbit
use http/http2/frame { decode_frame }
use @tsp = @ZSeanYves/MoonbitHTTP/transport

let raw : Array[Byte] = [
  0, 0, 4,    // length = 4
  0x4, 0x0,   // type=SETTINGS, flags=0
  0, 0, 0, 0  // stream_id = 0
]
let io  = @tsp.from_inmemory(raw)
let f   = decode_frame(io).unwrap()
// match f { Frame::Settings(settings) => ..., _ => ... }
```

**Encoding** (example: SETTINGS frame):

```moonbit
use http/http2/frame { encode_settings_frame, SettingPair }

let settings : Array[SettingPair] = [
  { id: 0x1, value: 4096 }, // HEADER_TABLE_SIZE
  { id: 0x3, value: 100 },  // MAX_CONCURRENT_STREAMS
]

let bytes = encode_settings_frame(settings, false)
// send `bytes` over your Transport
```

For other frame types you will find corresponding helpers such as:

* `encode_data_frame(stream_id, payload, end_stream)`
* `encode_headers_frame(stream_id, header_block, end_headers)`
* `encode_ping(ping_bytes, ack)`
* `encode_goaway(last_stream_id, error_code, debug_data)`
* `encode_window_update(stream_id, increment)`

> Exact signatures may differ slightly, but the intent is always: **build a valid HTTP/2 frame into a byte array**.

### 4.3 HPACK (Static Table)

The `hpack` module provides uint8-level HPACK processing for header blocks:

* `hpack_encode(headers: Array[(String, String)]) -> Array[Byte]`
* `hpack_decode(bytes: Array[Byte]) -> Array[(String, String)]`

Current implementation:

* Uses **only the static table** defined by the HPACK spec
* Supports **literal header fields without indexing**
* Rejects / errors on attempts to modify the dynamic table size

Example – decoding a header block:

```moonbit
use http/http2/hpack { hpack_decode }
use @buf = @ZSeanYves/bufferutils

let encoded = @buf.string_to_utf8_bytes("\x82\x86\x84").to_array()
let headers = hpack_decode(encoded)
// headers: Array[(String,String)]
```

Example – encoding a small header list:

```moonbit
use http/http2/hpack { hpack_encode }

let headers : Array[(String, String)] = [
  (":method", "GET"),
  ("host", "example.com"),
]

let encoded_block = hpack_encode(headers)
// `encoded_block` can be used inside a HEADERS frame
```

---

## 5. Putting It Together — Minimal Inspector Example

This example shows how you might wire the building blocks to **inspect incoming frames** from a `Transport`:

```moonbit
use http/http2/preface { detect_client_preface }
use http/http2/frame   { decode_frame, Frame }
use @tsp = @ZSeanYves/MoonbitHTTP/transport

// Assume `rx` is raw bytes captured from a client attempting HTTP/2
fn inspect_connection(rx: Array[Byte]) {
  let io = @tsp.from_inmemory(rx)
  let preface_bytes = io.peek(24)   // example: read first N bytes without consuming

  if !detect_client_preface(preface_bytes) {
    // Not HTTP/2, maybe HTTP/1.1 or garbage
    return
  }

  // Consume the preface bytes (implementation-specific)
  let _ = io.consume(preface_bytes.length())

  // Now loop over frames
  loop {
    match decode_frame(io) {
      Err(e) => {
        // handle EOF / protocol error
        break
      }
      Ok(f) => {
        match f {
        | Frame::Settings(s) => {
            // print settings, etc.
          }
        | Frame::Data(d) => {
            // inspect DATA payload
          }
        | Frame::Headers(h) => {
            // inspect HEADERS (header_block); you can further call hpack_decode
          }
        | _ => {
            // other frame types
          }
        }
      }
    }
  }
}
```

> This is deliberately low-level: all connection semantics (when to stop, when to send SETTINGS, etc.) are in the caller's hands.

---

## 6. Integration with Other MoonbitHTTP Modules

Typical layering when you eventually build a full HTTP stack:

* `transport` — in-memory or real network IO
* `http2` — frames, HPACK, preface detection
* (future) `http2_runtime` — stream state machine, flow control, request/response mapping
* `core` — `Request`, `Response`, `StatusCode`, `Body`, `Limits`, etc.

At the moment, `http2` deliberately **stops** at the frame + HPACK layer so that it remains:

* Safe to experiment with
* Easy to test in isolation
* Flexible enough for different runtime designs (server, proxy, tunneling tools, etc.)

---

## 7. Current Limitations & Non‑Goals

* ❌ No ready-to-use HTTP/2 server or client
* ❌ No automatic SETTINGS / ACK handling
* ❌ No flow-control window accounting
* ❌ No prioritization / dependency tree for streams
* ❌ No server push
* ❌ No TLS / ALPN negotiation
* ❌ No HTTP/1.1 ↔ HTTP/2 upgrade logic built in

All of the above are **planned for future layers** built on top of this package, not inside it.

---

## 8. Roadmap

Planned (subject to change):

* [ ] Basic HTTP/2 runtime package (single-connection, limited streams)
* [ ] Flow-control handling at connection and stream levels
* [ ] HPACK dynamic table and header compression tuning
* [ ] Multiplexing utilities and simple request/response mapping
* [ ] Integration helpers to auto-detect HTTP/1.1 vs HTTP/2

For now, treat `http2` as a **low-level protocol toolbox** rather than a full framework.

---

## 9. License

This module is released under the **MIT License**, same as the rest of MoonbitHTTP.
