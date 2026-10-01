///|
test "QUIC Retry integrity matches RFC 9001 Appendix A.4" {
  let original = b"\x83\x94\xc8\xf0\x3e\x51\x57\x08"
  let retry_without_tag = b"\xff\x00\x00\x00\x01\x00\x08\xf0\x67\xa5\x50\x2a\x42\x62\xb5\x74\x6f\x6b\x65\x6e"
  let expected = b"\x04\xa2\x65\xba\x2e\xff\x4d\x82\x90\x58\xfb\x3f\x0f\x24\x96\xba"
  let tag = @tls.quic_retry_integrity_tag(original, retry_without_tag).unwrap()
  assert_eq(tag, expected)
  @tls.quic_verify_retry_integrity(original, retry_without_tag, expected).unwrap()
  let changed = retry_without_tag.to_array()
  changed[changed.length() - 1] = changed[changed.length() - 1] ^ 1
  assert_true(
    @tls.quic_verify_retry_integrity(
      original,
      Bytes::from_array(changed),
      expected,
    )
    is Err(PacketAuthenticationFailed),
  )
}
