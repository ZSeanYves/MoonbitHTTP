// http1/handler.mbt — 读一次请求，调用用户处理函数，写回响应（最小闭环）

// ---- 简易请求结构（不含 body） ----
pub struct Request {
  line    : RequestLine
  headers : Map[String, String]
}

// 处理函数类型：输入 Request，返回 (状态码, 头, body字节数组, 是否chunked)
// PS： 若 is_chunked = false，则由编码器生成 Content-Length。
//      若 is_chunked = true，则你必须在 headers 里设置 "Transfer-Encoding":"chunked"；编码器按 chunked 输出。
//handler    : (Request) -> (StatusCode, Map[String,String], Array[Byte], Bool)

// ---- 工具：把 Array[Byte] 的前 n 个字节复制出来（避免 slice） ----
fn copy_first(bs : Array[Byte], n : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < n { out.push(bs[i]); i += 1 }
  out
}

// ---- 从 Transport 读到 BufCursor，直到可解析出一行（或读尽） ----
fn read_once_into(cur : @tsp.BufCursor, io : @tsp.Transport, win : Int) -> Result[Int, String] {
  let buf : Array[Byte] = []
  buf.resize(win, 0)
  match io.read(buf) {
    Ok(n) => {
      if n > 0 {
        let chunk = copy_first(buf, n)
        cur.buf_push(chunk)
      }
      Ok(n)
    }
    Err(@tsp.IoError::WouldBlock) => Ok(0)
    Err(@tsp.IoError::Eof)        => Err("eof while reading")
    Err(@tsp.IoError::Closed)     => Err("closed while reading")
  }
}

pub fn serve_once(
  io : @tsp.Transport,
  handler : (Request) -> (StatusCode, Map[String, String], Array[Byte], Bool),
  max_headers : Int,
  max_line : Int,
  read_win : Int,
) -> Result[Unit, String] {
  let cur = @tsp.buf_new()

  // 解析请求行
  let req_line : RequestLine = {
    let mut out_ok = false
    let mut out : RequestLine = {
      http_method: Method::GET,
      target: "",
      version: "",
    } // 占位初始化，请按你定义的字段名改
    let mut rounds = 0
    while true {
      match parse_request_line(cur) {
        Ok(rl) => {
          out = rl
          out_ok = true
          break
        }
        Err(_) => {
          let n = match read_once_into(cur, io, read_win) {
            Ok(n) => n
            Err(e) => return Err(e)
          }
          ignore(n)
          rounds += 1
          if rounds > 1024 {
            return Err("too many read rounds (request line)")
          }
        }
      }
    }
    if !out_ok {
      return Err("unreachable: request line not parsed")
    }
    out
  }

  // 解析头部
  let req_headers : Map[String, String] = {
    let mut out_ok = false
    let mut out : Map[String, String] = Map::new()
    let mut rounds = 0
    while true {
      match parse_headers(cur, max_headers, max_line) {
        Ok(hs) => {
          out = hs
          out_ok = true
          break
        }
        Err(_) => {
          let n = match read_once_into(cur, io, read_win) {
            Ok(n) => n
            Err(e) => return Err(e)
          }         
          ignore(n)
          rounds += 1
          if rounds > 1024 {
            return Err("too many read rounds (headers)")
          }
        }
      }
    }
    if !out_ok {
      return Err("unreachable: headers not parsed")
    }
    out
  }
  let req = { line: req_line, headers: req_headers }
  let (status, resp_headers, resp_body, is_chunked) = handler(req)
  let content_len = if is_chunked { 0 } else { resp_body.length() }
  let resp_str = encode_response(status, resp_headers, resp_body, content_len)
  let resp_bs = @buf.string_to_utf8_bytes(resp_str).to_array()
  match (try? io.write_all(resp_bs)) {
    Ok(_) => Ok(())
    Err(_) => Err("write_all failed ")
  }
}


// http1/handler_test.mbt — 端到端：读请求 → 回响应（不含请求体）



// 一个最简单的处理器：无论请求什么都返回 200 text/plain: "Hello"
pub fn hello_handler(req : Request) -> (StatusCode, Map[String,String], Array[Byte], Bool) {
  ignore(req) // 先不看请求

  let hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")

  let body = @buf.string_to_utf8_bytes("Hello, MoonBit!").to_array()

  (StatusCode::OK, hs, body, false) // 非 chunked，自动 Content-Length
}


// 一个 chunked 处理器：返回两行拼起来的 body
pub fn chunked_handler(req : Request) -> (StatusCode, Map[String,String], Array[Byte], Bool) {
  ignore(req)

  let hs : Map[String,String] = Map::new()
  hs.set("Content-Type", "text/plain")
  hs.set("Transfer-Encoding", "chunked")

  // body 一次性给出，编码器会按 chunked 分块；为了可预期，给一个短 body
  let body = @buf.string_to_utf8_bytes("Hello, world!").to_array()
  (StatusCode::OK, hs, body, true)
}

///TODO