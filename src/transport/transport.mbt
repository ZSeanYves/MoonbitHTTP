pub struct Transport {
  mut rx : Array[Byte]
  mut tx : Array[Byte] //一个镜像数组，便于 take_tx 返回
  txw : @buf.BufferWriter
  mut is_closed : Bool
}

// 构造：初始化一个写缓冲 writer
pub fn from_inmemory(bs : Array[Byte]) -> Transport raise @buf.BufferError {
  { rx: bs, tx: [], txw: @buf.new_writer(256), is_closed: false }
}

// —— writer ——
// 写，返回本次写入长度
pub fn write(
  self : Transport,
  src : Array[Byte],
) -> Result[Int, IoError] raise @buf.BufferError {
  if self.is_closed {
    return Err(IoError::Closed)
  }
  let snapshot = @buf.write_Abyte(self.txw, src) 
  self.tx = snapshot // 维护一份镜像，方便 take_tx
  Ok(self.tx.length())
}

// flush：相当于 no-op
pub fn flush(self : Transport) -> Result[Unit, IoError] {
  if self.is_closed {
    return Err(IoError::Closed)
  }
  Ok(())
}

// 取走写缓冲：清空 txw 与本地镜像
pub fn take_tx(self : Transport) -> Array[Byte] {
  let out = self.tx
  self.txw.clear() 
  self.tx = []
  out
}

// —— reader ——
// 读：把最多 dst.length() 字节读入 dst；消耗 rx 的前缀
// - rx 为空且未关闭：WouldBlock
// - rx 为空且已关闭：Eof
pub fn read(self : Transport, dst : Array[Byte]) -> Result[Int, IoError] {
  if self.rx.length() == 0 {
    if self.is_closed { return Err(IoError::Eof) }
    return Err(IoError::WouldBlock)
  }
  let n = if dst.length() < self.rx.length() { dst.length() } else { self.rx.length() }
  let mut i = 0
  while i < n { dst[i] = self.rx[i]; i += 1 }
  // 前缀消费
  let rest : Array[Byte] = []
  while i < self.rx.length() { rest.push(self.rx[i]); i += 1 }
  self.rx = rest
  Ok(n)
}

// 读满 n 字节；不足则 Eof；遇到 WouldBlock 会继续尝试
pub fn read_exact(self : Transport, n : Int) -> Result[Array[Byte], IoError] {
  let out : Array[Byte] = []
  out.resize(n, 0)
  let mut off = 0
  while off < n {
    let need = n - off
    let win : Array[Byte] = []
    win.resize(need, 0)
    let got = match self.read(win) {
      Ok(x) => x
      Err(IoError::WouldBlock) => { continue }   // 简易重试；上层也可选择改为立即返回
      Err(e) => { return Err(e) }
    }
    if got == 0 { return Err(IoError::Eof) }
    let mut i = 0
    while i < got { out[off + i] = win[i]; i += 1 }
    off += got
  }
  Ok(out)
}



// —— tool ——
// 模拟“网络到达”：把 chunk 追加到 rx（供 read()/read_exact() 消费）
pub fn push_rx(self : Transport, chunk : Array[Byte]) -> Unit {
  for b in chunk { self.rx.push(b) }
}

// 关闭连接：read 无数据时返回 Eof；write/flush 返回 Closed
pub fn close(self : Transport) -> Result[Unit, IoError] {
  self.is_closed = true
  Ok(())
}

// TODO
pub fn write_all(self : Transport, src : Array[Byte]) -> Result[Unit, IoError] raise @buf.BufferError {
  if self.is_closed { return Err(IoError::Closed) }
  let mut off = 0
  while off < src.length() {
    let chunk : Array[Byte] = []
    let mut i = off
    while i < src.length() { chunk.push(src[i]); i += 1 }
    let wrote = match self.write(chunk) {
      Ok(w) => w
      Err(IoError::WouldBlock) => { continue }
      Err(e) => { return Err(e) }
    }
    if wrote == 0 { return Err(IoError::WouldBlock) }
    off += wrote
  }
  ignore(self.flush())
  Ok(())
}

// 查看当前可读字节数（解析器可以用它决定是否继续拼一行）
pub fn rx_len(self : Transport) -> Int { self.rx.length() }