///|
test "hpack: integer and header-list overflow fail before allocation" {
  let overflowing = b"\xff\xff\xff\xff\xff\x7f"
  assert_eq(decode_integer(overflowing, 0, 7), Err("hpack int: overflow"))
  let context = HpackContext::new(max_header_list_size=34)
  assert_true(
    context.encode_incremental([{ name: "x", value: b"yy", }])
    is Err(ConnectionError(EnhanceYourCalm, _)),
  )
}
