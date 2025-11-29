///|
pub(all) enum Body {
  Empty
  Bytes(Array[Byte])
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

// 小工具：返回内容长度（若非 Bytes 则未知）

///|
pub fn body_len(b : Body) -> Int {
  match b {
    Body::Empty => 0
    Body::Bytes(bs) => bs.length()
  }
}
