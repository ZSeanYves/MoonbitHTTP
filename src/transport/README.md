# MoonbitHTTP/transport

## Overview

A tiny, test‑friendly **transport layer** for MoonBit HTTP projects, plus a **buffer cursor** for incremental parsing.

* **In‑memory transport `Transport`**: feed incoming bytes (simulate “network arrival”), read them out, write responses, and drain the send buffer for assertions.
* **Parser buffer `BufCursor`**: accumulate chunks, **split lines by CRLF**, or take fixed‑length prefixes—ideal for HTTP/1.1 start‑line/headers and bodies.

This package intentionally does **no real networking** (no TCP/TLS). It’s a clean, portable foundation you can unit‑test against; a `uv.mbt` adapter can be added later.

---

## Usage

### 1) Minimal round‑trip (write a response & take it)

```moonbit
use http/transport {
  from_inmemory,
}
use @buf = @ZSeanYves/bufferutils

let io = from_inmemory([])

// encode a tiny 200 OK
let resp = @buf.string_to_utf8_bytes(
  "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello"
)

// write all → drain what we “sent”
let _ = io.write_all(resp.to_array())
let out = io.take_tx()

//println(Bytes::from_array(out).to_string())
```

### 2) Simulate network fragments → read with a temp buffer

```moonbit
use http/transport { from_inmemory }
use @buf = @ZSeanYves/bufferutils

let io = from_inmemory([])
io.push_rx(@buf.string_to_utf8_bytes("GET / HT").to_array())
io.push_rx(@buf.string_to_utf8_bytes("TP/1.1\r\n").to_array())

let buf : Array[Byte] = []
buf.resize(1024, 0.to_byte())

match io.read(buf) {
  Ok(n) => {
    let line = Bytes::from_array(buf.slice(0, n)).to_string()
    //println("got: {}", line)
  }
  Err(IoError::WouldBlock) => //println("no data yet"),
  Err(e) => //println("read err: {:?}", e)
}
```

### 3) Parse lines with `BufCursor` (CRLF)

```moonbit
use http/transport { buf_new }
use @buf = @ZSeanYves/bufferutils

let cur = buf_new()
cur.buf_push(@buf.string_to_utf8_bytes("Host: a\r\n").to_array())
cur.buf_push(@buf.string_to_utf8_bytes("User-Agent: x\r\n").to_array())

let l1 = cur.buf_read_line_crlf(8 * 1024).unwrap()
let l2 = cur.buf_read_line_crlf(8 * 1024).unwrap()
//println(Bytes::from_array(l1).to_string()) // "Host: a"
//println(Bytes::from_array(l2).to_string()) // "User-Agent: x"
```

> Tip: `WouldBlock` means “no data for now”; `Eof` means the input stream has ended (usually after `close()` and the rx buffer is empty).

---

## API

### Transport (in‑memory backend)

```moonbit
struct Transport {
  // rx: incoming bytes pool (consumed by read)
  // txw: write buffer (managed by bufferutils)
  // tx:  mirror snapshot for take_tx()
  // is_closed: closed state
}

fn from_inmemory(bs : Array[Byte]) -> Transport
```

**Reading**

```moonbit
fn Transport.read(dst : Array[Byte]) -> Result[Int, IoError]
// Copies up to dst.length() from rx, and CONSUMES that prefix.
// Empty+not-closed -> Err(WouldBlock); empty+closed -> Err(Eof)

fn Transport.read_exact(n : Int) -> Result[Array[Byte], IoError]
// Blocking style: loops until n bytes are read, or Err(Eof/Closed).
// Callers should ensure enough bytes have been push_rx()’d first.
```

**Writing**

```moonbit
fn Transport.write(src : Array[Byte]) -> Result[Int, IoError]
// Appends to the write buffer; returns count written.

fn Transport.write_all(src : Array[Byte]) -> Result[Unit, IoError]
// Ensures the whole slice is written (loops internally).

fn Transport.flush() -> Result[Unit, IoError]
// No-op for in-memory backend; kept for API parity.
```

**Lifecycle & helpers**

```moonbit
fn Transport.push_rx(chunk : Array[Byte]) -> Unit
// Simulate “network arrival”: append chunk to rx.

fn Transport.take_tx() -> Array[Byte]
// Drain the currently written bytes (and clear the send buffer).

fn Transport.close() -> Result[Unit, IoError]
// After close: read on empty -> Eof; write/flush -> Closed.

fn Transport.rx_len() -> Int
// Current unread bytes in rx.
```

**Errors**

```moonbit
suberror IoError {
  Eof         // input stream ended (empty + closed)
  Closed      // writing/flushing after close
  WouldBlock  // temporarily no data to read/write
  Timeout     // reserved for real backends
  Other(String)
}
```

### BufCursor (incremental parsing buffer)

Constructor:

```moonbit
fn buf_new() -> BufCursor
```

Methods:

```moonbit
fn BufCursor.buf_push(chunk : Array[Byte]) -> Unit
fn BufCursor.buf_len() -> Int
fn BufCursor.buf_is_empty() -> Bool

fn BufCursor.buf_read_line_crlf(max_len : Int) -> Result[Array[Byte], BufError]
// Returns a line WITHOUT CRLF and CONSUMES "line + CRLF".
// NeedMore if CRLF not found yet; LineTooLong if exceeds max_len.

fn BufCursor.buf_take(n : Int) -> Array[Byte]  // consume up to n bytes
fn BufCursor.buf_peek(n : Int) -> Array[Byte]  // peek up to n bytes (no consume)
fn BufCursor.buf_drain(n : Int) -> Int         // drop prefix n bytes; return dropped count
```

Errors:

```moonbit
suberror BufError {
  NeedMore(String)
  LineTooLong(String)
}
```

---

## Notes

* Bytes helpers in examples use **bufferutils**:

  ```moonbit
  use @buf = @ZSeanYves/bufferutils
  @buf.string_to_utf8_bytes("...").to_array()
  ```
* When creating temp buffers for reading, prefer:

  ```moonbit
  let buf : Array[Byte] = []
  buf.resize(1024, 0.to_byte())
  ```
* `read_exact` is **blocking‑style** here to simplify early tests. In real networking, consider a **non‑blocking** variant that returns `WouldBlock` and lets the caller retry after new data arrives.

---

## Example: read start‑line & echo back

```moonbit
use http/transport { from_inmemory, buf_new }
use @buf = @ZSeanYves/bufferutils

let io  = from_inmemory(@buf.string_to_utf8_bytes("GET / HTTP/1.1\r\n\r\n").to_array())
let cur = buf_new()

let tmp : Array[Byte] = []
tmp.resize(64, 0.to_byte())
match io.read(tmp) {
  Ok(n) => cur.buf_push(tmp.slice(0, n))
  _ => ()
}

let line = cur.buf_read_line_crlf(8 * 1024).unwrap()
//println(Bytes::from_array(line).to_string()) // "GET / HTTP/1.1"

let resp = @buf.string_to_utf8_bytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
let _ = io.write_all(resp.to_array())
let out = io.take_tx()
//println(Bytes::from_array(out).to_string())
```
