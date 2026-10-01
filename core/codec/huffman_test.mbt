///|
test "huffman: RFC 7541 C.4.1 www.example.com vector" {
  let raw = b"www.example.com"
  let encoded = b"\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff"
  assert_eq(@codec.huffman_encode(raw), encoded)
  assert_eq(@codec.huffman_decode(encoded), Ok(raw))
}

///|
test "huffman: all byte values round-trip including long codes after residual bits" {
  let bytes = Bytes::from_array(
    Array::makei(256, fn(index) { index.to_byte() }),
  )
  assert_eq(@codec.huffman_decode(@codec.huffman_encode(bytes)), Ok(bytes))
  for byte in bytes {
    let raw = Bytes::from_array([b'a', byte, b'z', byte, b'0'])
    assert_eq(@codec.huffman_decode(@codec.huffman_encode(raw)), Ok(raw))
  }
  assert_eq(@codec.huffman_encode(b""), b"")
  assert_eq(@codec.huffman_decode(b""), Ok(b""))
}

///|
test "huffman: EOS and invalid padding retain distinct typed errors" {
  assert_eq(@codec.huffman_decode(b"\xff\xff\xff\xff"), Err(UnexpectedEos))
  assert_eq(@codec.huffman_decode(b"\xff"), Err(InvalidPadding))
  assert_eq(@codec.huffman_decode(b"\x00"), Err(InvalidPadding))
  assert_eq(@codec.huffman_decode(b"\x1f"), Ok(b"a"))
}
