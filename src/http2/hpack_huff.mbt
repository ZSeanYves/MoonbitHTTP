///|
fn table_init() -> Map[Int, HuffSym] {
  let t : Map[Int, HuffSym] = Map::new()
  t.set(47, { code: 0x18, bits: 6 })

  // 常用：'0'..'9'（48..57） 
  // t.set(48, { code: ..., bits: ... })
  // ...

  // 常用：小写字母 'a'..'z'（97..122）
  // t.set(97,  { code: ..., bits: ... })
  // ...

  // 常用：':', '-', '.', '_', ' ' 等
  // t.set(58,  { code: ..., bits: ... })
  // t.set(45,  { code: ..., bits: ... })
  // t.set(46,  { code: ..., bits: ... })

  // PS：EOS（符号 256）
  // t.set(256, { code: 0x3fffffff, bits: 30 }) // 示例占位，用 RFC 的真实值
  t
}

// 构建“按位前缀”查找树,加速解码

///|
fn build_trie(tbl : Map[Int, HuffSym]) -> Array[HuffNode] {
  let nodes : Array[HuffNode] = []
  // root
  nodes.push({ left: -1, right: -1, sym: -1 })
  for sym in tbl.keys() {
    let hs = match tbl.get(sym) {
      Some(x) => x
      None => continue
    }
    let mut cur = 0
    let mut i = hs.bits
    while i > 0 {
      i -= 1
      let bit = (hs.code >> i) & 1

      // 读取父节点的当前快照
      let parent = nodes[cur]
      if bit == 0 {
        let next = if parent.left == -1 {
          nodes.push({ left: -1, right: -1, sym: -1 })
          nodes.length() - 1
        } else {
          parent.left
        }
        nodes[cur] = { left: next, right: parent.right, sym: parent.sym }
        cur = next
      } else {
        let next = if parent.right == -1 {
          nodes.push({ left: -1, right: -1, sym: -1 })
          nodes.length() - 1
        } else {
          parent.right
        }
        nodes[cur] = { left: parent.left, right: next, sym: parent.sym }
        cur = next
      }
    }

    // 设置叶子：同样重建整节点写回
    let leaf = nodes[cur]
    nodes[cur] = { left: leaf.left, right: leaf.right, sym }
  }
  nodes
}

// 解码 

///|
pub fn hpack_huff_decode(data : Array[Byte]) -> Result[Array[Byte], String] {
  let tbl = table_init()
  let trie = build_trie(tbl)
  let out : Array[Byte] = []
  let mut node = 0

  // 逐字节，从 MSB 到 LSB
  for b in data {
    let mut i = 7
    while i >= 0 {
      let bit = (b.to_int() >> i) & 1
      // 走树
      node = if bit == 0 {
        if trie[node].left == -1 {
          return Err("hpack huffman: invalid path (0)")
        }
        trie[node].left
      } else {
        if trie[node].right == -1 {
          return Err("hpack huffman: invalid path (1)")
        }
        trie[node].right
      }
      if trie[node].sym >= 0 {
        let sym = trie[node].sym
        if sym == 256 {
          return Err("hpack huffman: EOS encountered in data")
        }
        out.push(sym.to_byte())
        node = 0
      }
      i -= 1
    }
  }

  // 由于还未有完整表，这里仅做“停在根”的宽松校验；待表补全后可严格对比 EOS 前缀。
  // TODO: 补全表后改进此处
  if node != 0 {
    // 这里保守返回错误，避免吞掉真实非法编码
    return Err(
      "hpack huffman: non-root at end (padding check needs full table)",
    )
  }
  Ok(out)
}

// ===== 编码 

///|
pub fn hpack_huff_encode(raw : Array[Byte]) -> Result[Array[Byte], String] {
  let tbl = table_init()
  let mut bitbuf : Int = 0
  let mut bitlen : Int = 0
  let out : Array[Byte] = []
  for ch in raw {
    match tbl.get(ch.to_int()) {
      Some(hs) => {
        bitbuf = (bitbuf << hs.bits) | hs.code
        bitlen += hs.bits
        while bitlen >= 8 {
          bitlen -= 8
          let byte = ((bitbuf >> bitlen) & 0xff).to_byte()
          out.push(byte)
        }
      }
      None =>
        return Err(
          "hpack huffman: symbol not in table: " + ch.to_int().to_string(),
        )
    }
  }

  // 末尾填充（用 EOS 的高位）到下一个字节边界
  if bitlen > 0 {
    // TODO: 补全表后可用 EOS 的前缀位填充
    // let eos = tbl.get(256).unwrap()  // code/bits
    // let padbits = 8 - bitlen
    // let padmask = (eos.code >> (eos.bits - padbits)) & ((1 << padbits) - 1)
    // let last = ((bitbuf << padbits) | padmask) & 0xff
    // out.push(last.to_byte())

    // 占位：简单把剩余位用全 1 补齐（很多实现等价于 EOS 前缀）
    let padbits = 8 - bitlen
    let last = ((bitbuf << padbits) | ((1 << padbits) - 1)) & 0xff
    out.push(last.to_byte())
  }
  Ok(out)
}
