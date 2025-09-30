// 从字符串 s 中截取 [start, end) 区间，返回新字符串
pub fn str_slice(s:String, start:Int, end:Int) -> String {
  let mut out = ""
  let mut i = start
  while i < end && i < s.length() {
    out = out + s[i].to_string()
    i += 1
  }
  out
}

// 提取字节数组中的一个切片
pub fn byte_slice(bytes: Array[Byte], start: Int, end: Int) -> Array[Byte] {
  let slice : Array[Byte] = []
  for i in start..<end {
    slice.push(bytes[i])
  }
  slice
}


// 将正整数转换为 16 进制字符串（小写），用于 chunked 块长度
pub fn _int_to_hex(n : Int) -> String {
  if n == 0 {
    return "0"
  }
  let table : Array[Byte] = @buf.string_to_utf8_bytes("0123456789abcdef").to_array()
  let out : Array[Byte] = []
  let mut m = n
  while m > 0 {
    let d = m % 16
    out.push(table[d])
    m = m / 16
  }
  // 把低位在前的数组翻转为正常顺序
  let mut i = 0
  let mut j = out.length() - 1
  while i < j {
    let tmp = out[i]
    out[i] = out[j]
    out[j] = tmp
    i += 1
    j -= 1
  }
  match (try? @buf.utf8_bytes_to_string(Bytes::from_array(out))) {
    Ok(s) => s
    Err(_) => "0"
  }
}

// 解析 16 进制数字（块大小）
pub fn _hex_to_int(s : String) -> Result[Int, String] {
  if s.length() == 0 {
    return Err("empty chunk size")
  }
  let bs = @buf.string_to_utf8_bytes(s).to_array()
  let mut i = 0
  let mut n : Int = 0
  while i < bs.length() {
    let d = bs[i].to_int()
    let v = if d >= 48 && d <= 57 {
      d - 48 // 0-9
    } else if d >= 65 && d <= 70 {
      d - 55 // A-F
    } else if d >= 97 && d <= 102 {
      d - 87 // a-f
    } else {
      return Err("invalid hex digit in chunk size: " + s)
    }
    n = n * 16 + v
    i += 1
  }
  Ok(n)
}

// 把 ASCII 字符串追加到 out
pub fn push_ascii(dst : Array[Byte], s : String) -> Array[Byte] {
  let bs = @buf.string_to_utf8_bytes(s).to_array()
  for b in bs {
    dst.push(b)
  }
  dst
}
// ASCII 字符串的便捷函数
pub fn write_ascii(io : @tsp.Transport, s : String) -> Result[Unit, String] {
  let bs = @buf.string_to_utf8_bytes(s).to_array()
  match (try? io.write_all(bs)) {
     Ok(_) => Ok(())
    Err(_) => Err("write ascii failed ")
  }
}

// 把 Array[Byte] 的前 n 个字节复制出来（避免 slice）
pub fn copy_first(bs : Array[Byte], n : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < n { out.push(bs[i]); i += 1 }
  out
}

