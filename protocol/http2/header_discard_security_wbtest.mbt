///|
test "hpack short literal fields after a large update prefix preserve decoding" {
  let block : Array[Byte] = []
  for _ in 0..<60000 {
    block.push(0x20)
  }
  for _ in 0..<1000 {
    block.append([0, 1, 120, 1, 118])
  }
  let decoded = HpackContext::new().decode(Bytes::from_array(block)).unwrap()
  assert_eq(decoded.length(), 1000)
  assert_true(
    decoded.all(fn(header) { header.name == "x" && header.value == b"v" }),
  )
  // Both indexed-name and literal-name paths also retain Huffman validation.
  let encoded : Array[Byte] = [0]
  encoded.append(encode_string(b"x-custom", use_huffman=true))
  encoded.append(encode_string(b"a literal value", use_huffman=true))
  assert_eq(HpackContext::new().decode(Bytes::from_array(encoded)).unwrap(), [
    { name: "x-custom", value: b"a literal value", },
  ])
}
