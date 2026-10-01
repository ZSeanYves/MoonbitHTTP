///|
test "quic frame codec: canonical round trips preserve protocol fields" {
  let stream = @quic.StreamFrame::new(4L, 12L, b"payload", true).unwrap()
  let ack_range = @quic.AckRange::new(20L, 18L).unwrap()
  let ack = @quic.AckFrame::new(
    20L,
    3L,
    [ack_range],
    ecn_counts=Some((1L, 2L, 3L)),
  ).unwrap()
  let cid = @quic.ConnectionId::new(b"peer").unwrap()
  let frames : Array[@quic.QuicFrame] = [
    Padding,
    Ping,
    Ack(ack),
    ResetStream(4L, 7L, 19L),
    StopSending(4L, 8L),
    Crypto(0L, b"tls"),
    NewToken(b"token"),
    Stream(stream),
    MaxData(100L),
    MaxStreamData(4L, 80L),
    MaxStreams(true, 3L),
    DataBlocked(100L),
    StreamDataBlocked(4L, 80L),
    StreamsBlocked(false, 3L),
    NewConnectionId(
      1L,
      0L,
      cid,
      Bytes::from_array(FixedArray::make(16, b'\x01')),
    ),
    RetireConnectionId(1L),
    PathChallenge(b"12345678"),
    PathResponse(b"abcdefgh"),
    ConnectionClose(false, 1L, 0L, b"close"),
    ConnectionClose(true, 2L, 0L, b"app"),
    HandshakeDone,
    Datagram(b"datagram"),
  ]
  let encoded = @quic.quic_encode_frames(frames).unwrap()
  let decoded = @quic.quic_decode_frames(encoded).unwrap()
  assert_eq(decoded, frames)
}

///|
test "quic frame codec: malformed ranges and oversized values fail" {
  assert_true(
    @quic.AckFrame::new(10L, 0L, [@quic.AckRange::new(9L, 9L).unwrap()])
    is Err(_),
  )
  assert_true(
    @quic.quic_encode_frame(
      Stream(@quic.StreamFrame::new(0L, 0L, b"x", false).unwrap()),
      limits={ ..@quic.QuicLimits::defaults(), max_frame_payload: 0, },
    )
    is Err(_),
  )
}
