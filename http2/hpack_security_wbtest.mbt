///|
test "hpack: field values round-trip as opaque bytes" {
  let encoder = HpackContext::new()
  let decoder = HpackContext::new()
  let raw = Bytes::from_array([0x80, 0xff, b'\t'])
  let encoded = encoder
    .encode_incremental([{ name: "x-opaque", value: raw, }])
    .unwrap()
  let decoded = decoder.decode(encoded).unwrap()
  assert_eq(decoded, [{ name: "x-opaque", value: raw, }])
}

///|
test "hpack: sensitive fields are never indexed" {
  let encoder = HpackContext::new()
  let encoded = encoder
    .encode_incremental([{ name: "authorization", value: b"Bearer secret", }])
    .unwrap()
  assert_eq(encoder.table_length(), 0)
  assert_eq(encoded[0].to_int() & 0xf0, 0x10)
  let decoder = HpackContext::new()
  assert_eq(decoder.decode(encoded).unwrap(), [
    { name: "authorization", value: b"Bearer secret", },
  ])
  assert_eq(decoder.table_length(), 0)
}

///|
test "hpack: integer and header-list overflow fail before allocation" {
  let overflowing : Array[Byte] = [0xff, 0xff, 0xff, 0xff, 0xff, 0x7f]
  assert_eq(decode_integer(overflowing, 0, 7), Err("hpack int: overflow"))
  let context = HpackContext::new(max_header_list_size=34)
  assert_true(
    context.encode_incremental([{ name: "x", value: b"yy", }])
    is Err(ConnectionError(EnhanceYourCalm, _)),
  )
}
