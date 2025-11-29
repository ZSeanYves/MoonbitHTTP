# MoonbitHTTP/transport

## 概览

一个轻量、易于测试的 **传输层工具**，为 MoonBit HTTP 项目设计，同时提供一个 **缓冲游标**，方便增量解析。

* **内存传输 `Transport`**：模拟“网络到达”的数据流，可以注入字节、读取、写出响应，并获取发送缓冲内容用于断言。
* **解析缓冲 `BufCursor`**：积累字节块，支持 **按 CRLF 分行** 或读取定长前缀——非常适合处理 HTTP/1.1 的起始行、头部和消息体。

本工具**不提供真实网络**（没有 TCP/TLS）。它是一个简洁、可移植的基础设施，便于单元测试；后续可通过 `uv.mbt` 适配器对接真实网络。

---

## 使用方法

### 1) 最小往返（写出响应并读取）

```moonbit
use http/transport {
  from_inmemory,
}
use @buf = @ZSeanYves/bufferutils

let io = from_inmemory([])

// 构造一个最小的 200 OK 响应
let resp = @buf.string_to_utf8_bytes(
  "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello"
)

// 写入并取出“已发送”的数据
let _ = io.write_all(resp.to_array())
let out = io.take_tx()

//println(Bytes::from_array(out).to_string())
```

### 2) 模拟分片的网络数据 → 使用临时缓冲读取

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
  Err(IoError::WouldBlock) => //println("暂时没有数据"),
  Err(e) => //println("读取错误: {:?}", e)
}
```

### 3) 使用 `BufCursor` 按 CRLF 解析行

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

> 提示：`WouldBlock` 表示“暂时没有数据”；`Eof` 表示输入流已结束（通常是 `close()` 后且接收缓冲为空）。

---

## API

### Transport（内存后端）

```moonbit
struct Transport {
  // rx: 接收缓冲区（被 read 消费）
  // txw: 写缓冲区（由 bufferutils 管理）
  // tx:  take_tx() 的镜像快照
  // is_closed: 关闭状态
}

fn from_inmemory(bs : Array[Byte]) -> Transport
```

**读取**

```moonbit
fn Transport.read(dst : Array[Byte]) -> Result[Int, IoError]
// 从 rx 拷贝最多 dst.length() 字节，并消费这些字节。
// rx 空 + 未关闭 -> Err(WouldBlock)
// rx 空 + 已关闭 -> Err(Eof)

fn Transport.read_exact(n : Int) -> Result[Array[Byte], IoError]
// 阻塞式：循环读取直到获得 n 字节，或返回 Err(Eof/Closed)。
// 调用者需保证事先 push_rx 足够字节。
```

**写入**

```moonbit
fn Transport.write(src : Array[Byte]) -> Result[Int, IoError]
// 追加到写缓冲区，返回写入的字节数。

fn Transport.write_all(src : Array[Byte]) -> Result[Unit, IoError]
// 确保整个切片写入（内部循环）。

fn Transport.flush() -> Result[Unit, IoError]
// 内存后端中无操作；保留 API 兼容性。
```

**生命周期与辅助方法**

```moonbit
fn Transport.push_rx(chunk : Array[Byte]) -> Unit
// 模拟“网络到达”：把数据追加到 rx。

fn Transport.take_tx() -> Array[Byte]
// 取出并清空写缓冲区。

fn Transport.close() -> Result[Unit, IoError]
// 关闭后：若 rx 空则读 → Eof；写/flush → Closed。

fn Transport.rx_len() -> Int
// 返回 rx 当前未读字节数。
```

**错误**

```moonbit
suberror IoError {
  Eof         // 输入流结束（rx 空且已关闭）
  Closed      // 关闭后写/flush
  WouldBlock  // 暂时无数据可读/写
  Timeout     // 为真实后端预留
  Other(String)
}
```

### BufCursor（增量解析缓冲）

构造函数：

```moonbit
fn buf_new() -> BufCursor
```

方法：

```moonbit
fn BufCursor.buf_push(chunk : Array[Byte]) -> Unit
fn BufCursor.buf_len() -> Int
fn BufCursor.buf_is_empty() -> Bool

fn BufCursor.buf_read_line_crlf(max_len : Int) -> Result[Array[Byte], BufError]
// 返回不含 CRLF 的一行，并消费“行 + CRLF”。
// 若未找到 CRLF → NeedMore；若超出 max_len → LineTooLong。

fn BufCursor.buf_take(n : Int) -> Array[Byte]  // 消费前 n 字节
fn BufCursor.buf_peek(n : Int) -> Array[Byte]  // 查看前 n 字节，不消费
fn BufCursor.buf_drain(n : Int) -> Int         // 丢弃前 n 字节，返回丢弃数量
```

错误：

```moonbit
suberror BufError {
  NeedMore(String)
  LineTooLong(String)
}
```

---

## 注意事项

* 示例中的字节工具来自 **bufferutils**：

  ```moonbit
  use @buf = @ZSeanYves/bufferutils
  @buf.string_to_utf8_bytes("...").to_array()
  ```
* 临时缓冲推荐这样创建：

  ```moonbit
  let buf : Array[Byte] = []
  buf.resize(1024, 0.to_byte())
  ```
* `read_exact` 在这里是 **阻塞风格**，方便早期测试。在真实网络中建议用非阻塞方式：遇到 `WouldBlock` 时交由调用方重试。

---

## 示例：读取起始行并回显

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
