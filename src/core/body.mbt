///|
pub(all) enum Body {
  Empty
  Bytes(Array[Byte])
  // 流式 body：每次调用返回一块数据和是否结束
  // next() -> Ok((chunk_bytes, done))
  Stream(() -> Result[(Array[Byte], Bool), String])
}

// 便捷构造

///|
pub fn body_empty() -> Body {
  Body::Empty
}

///|
pub fn body_bytes(bs : Array[Byte]) -> Body {
  Body::Bytes(bs)
}

///|
/// 一个最简单的“单块流式”构造器：一次性把 bs 作为最后一块流出去
pub fn body_stream_from_bytes(bs : Array[Byte]) -> Body {
  let mut sent = false
  Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
    if sent {
      let empty : Array[Byte] = []
      Ok((empty, true))
    } else {
      sent = true
      Ok((bs, true))
    }
  })
}

// 小工具：返回内容长度（Stream 情况下返回 -1 表示未知）

///|
pub fn body_len(b : Body) -> Int {
  match b {
    Body::Empty => 0
    Body::Bytes(bs) => bs.length()
    Body::Stream(_) => -1  // unknown / streaming
  }
}
