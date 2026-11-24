///|
test "QUIC cumulative ACK preserves outstanding boundaries and untouched tail" {
  let sent : SentStreamRanges = { ranges: [], bytes: 0L, }
  sent.append(0L, 40L)
  for start in [4L, 12L, 20L, 28L] {
    assert_eq(sent.release(start, start + 4L), 4L)
  }
  assert_eq(sent.release(2L, 18L), 8L)
  assert_eq(sent.ranges, [(0L, 2L), (18L, 20L), (24L, 28L), (32L, 40L)])
  assert_eq(sent.release(2L, 18L), 0L)
  assert_eq(sent.release(2L, 28L), 6L)
  assert_eq(sent.bytes, 10L)
  assert_eq(sent.ranges, [(0L, 2L), (32L, 40L)])
}
