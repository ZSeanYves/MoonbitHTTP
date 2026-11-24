///|
test "hpack: field values round-trip as opaque bytes" {
  let encoder = @http2.HpackContext::new()
  let decoder = @http2.HpackContext::new()
  let raw = Bytes::from_array([0x80, 0xff, b'\t'])
  let encoded = encoder
    .encode_incremental([{ name: "x-opaque", value: raw, }])
    .unwrap()
  let decoded = decoder.decode(encoded).unwrap()
  assert_eq(decoded, [{ name: "x-opaque", value: raw, }])
}

///|
test "hpack: sensitive fields are never indexed" {
  let encoder = @http2.HpackContext::new()
  let encoded = encoder
    .encode_incremental([{ name: "authorization", value: b"Bearer secret", }])
    .unwrap()
  assert_eq(encoder.table_length(), 0)
  assert_eq(encoded[0].to_int() & 0xf0, 0x10)
  let decoder = @http2.HpackContext::new()
  assert_eq(decoder.decode(encoded).unwrap(), [
    { name: "authorization", value: b"Bearer secret", },
  ])
  assert_eq(decoder.table_length(), 0)
}
