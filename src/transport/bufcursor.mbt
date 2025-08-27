// 解析缓冲游标：累积 -> 查找 CRLF -> 切出一行/定长数据（供 http1 解码器使用）
pub struct BufCursor {
  mut buf : Array[Byte] // 累积的未消费字节
}

// 新建一个空的缓冲游标
pub fn buf_new() -> BufCursor {
  let bufcursor = { buf: [] }
  bufcursor
}

// 追加一段新到达的数据（例如来自 Transport.read() 的片段）
pub fn buf_push(self : BufCursor, chunk : Array[Byte]) -> Unit {
  for b in chunk {
    self.buf.push(b)
  }
}

// 当前缓冲可用字节数
pub fn buf_len(self : BufCursor) -> Int {
  self.buf.length()
}

// 是否为空
pub fn buf_is_empty(self : BufCursor) -> Bool {
  self.buf.length() == 0
}

// 内部：查找首次出现的 CRLF，返回 '\n' 的索引（即 CR 的下一个位置）
// 例如 buf = "... \r\n x", 若返回 i，则 line 为 [0 .. i-1)（不含 CRLF）
fn find_crlf(self : BufCursor) -> Int? {
  let mut i = 1
  let a = 0x0D
  let b = 0x0A
  while i < self.buf.length() {
    if self.buf[i - 1] == a.to_byte() && self.buf[i] == b.to_byte() {
      return Some(i) // i 指向 '\n' 位置
    }
    i += 1
  }
  None
}

// 读取一行（以 CRLF 结尾），返回不含 CRLF 的字节数组，并从缓冲中消费这一行 + CRLF。
// 如果当前没有完整的一行，则返回 NeedMore；若行太长，返回 LineTooLong。
pub fn buf_read_line_crlf(
  self : BufCursor,
  max_len : Int,
) -> Result[Array[Byte], BufError] {
  match self.find_crlf() {
    None => Err(BufError::NeedMore("need more bytes"))
    Some(nl_index) => {
      let line_len = nl_index - 1 // '\r' 的位置
      if line_len > max_len {
        return Err(BufError::LineTooLong("line too long"))
      }

      // 复制出一行（不含 CRLF）
      let line : Array[Byte] = []
      let mut i = 0
      while i < line_len {
        line.push(self.buf[i])
        i += 1
      }

      // 丢弃已读的行 + CRLF
      let rest : Array[Byte] = []
      let mut j = nl_index + 1 // 跳过 '\n'
      while j < self.buf.length() {
        rest.push(self.buf[j])
        j += 1
      }
      self.buf = rest
      Ok(line)
    }
  }
}

// 取走最多 n 字节（用于定长 Body 读取），并从缓冲中消费这 n 字节。
// 如果可用字节少于 n，则返回尽量多的那部分（由上层决定是否继续凑满）。
pub fn buf_take(self : BufCursor, n : Int) -> Array[Byte] {
  let m = if n < self.buf.length() { n } else { self.buf.length() }
  let out : Array[Byte] = []
  let mut i = 0
  while i < m {
    out.push(self.buf[i])
    i += 1
  }

  // 消费前缀
  let rest : Array[Byte] = []
  while i < self.buf.length() {
    rest.push(self.buf[i])
    i += 1
  }
  self.buf = rest
  out
}

// 仅窥视（不消费）前缀最多 n 字节
pub fn buf_peek(self : BufCursor, n : Int) -> Array[Byte] {
  let m = if n < self.buf.length() { n } else { self.buf.length() }
  let out : Array[Byte] = []
  let mut i = 0
  while i < m {
    out.push(self.buf[i])
    i += 1
  }
  out
}

// 丢弃前缀 n 字节，返回实际丢弃的数量（若不足 n，则全丢）
pub fn buf_drain(self : BufCursor, n : Int) -> Int {
  let m = if n < self.buf.length() { n } else { self.buf.length() }
  let rest : Array[Byte] = []
  let mut i = m
  while i < self.buf.length() {
    rest.push(self.buf[i])
    i += 1
  }
  self.buf = rest
  m
}
