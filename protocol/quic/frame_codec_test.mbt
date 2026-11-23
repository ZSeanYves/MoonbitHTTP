///|
test "quic frame codec: canonical round trips preserve protocol fields" {
  let stream = @quic.StreamFrame::new(4L, 12L, b"payload", true).unwrap()
  let ack_range = @quic.AckRange::new(20L, 18L).unwrap()
  let ack = @quic.AckFrame::new(
    20L,
    3L,
    [ack_range, { largest: 16L, smallest: 14L, }],
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
  // STREAM without LEN and DATAGRAM without LEN consume the packet remainder.
  // A frame field may use a wider varint. Only the frame type must be minimal.
  assert_eq(
    @quic.quic_decode_frames(b"\x01\x0d\x40\x04\x0cpayload"),
    Ok([Ping, Stream(stream)]),
  )
  assert_eq(
    @quic.quic_decode_frames(b"\x30\x01\x00"),
    Ok([Datagram(b"\x01\x00")]),
  )
  assert_true(@quic.quic_decode_frames(b"\x40\x01") is Err(NonCanonicalVarInt))
  assert_eq(
    @quic.quic_encode_frame(Ack(ack)).unwrap(),
    b"\x03\x14\x03\x01\x02\x00\x02\x01\x02\x03",
  )
}

///|
test "quic frame codec: stream counts, tokens and connection ID fields" {
  let max_streams = 1L << 60
  let frames : Array[@quic.QuicFrame] = [
    MaxStreams(false, max_streams),
    StreamsBlocked(true, max_streams),
  ]
  assert_eq(
    @quic.quic_decode_frames(@quic.quic_encode_frames(frames).unwrap()).unwrap(),
    frames,
  )
  for
    frame in [
      @quic.QuicFrame::MaxStreams(true, max_streams + 1L),
      StreamsBlocked(false, max_streams + 1L),
      NewToken(b""),
    ] {
    assert_true(@quic.quic_encode_frame(frame) is Err(Protocol(0x07L, _)))
  }
  for
    bytes in [
      b"\x12\xd0\x00\x00\x00\x00\x00\x00\x01", b"\x17\xd0\x00\x00\x00\x00\x00\x00\x01",
      b"\x07\x00", b"\x18\x00\x00\x00", b"\x18\x00\x01\x04",
    ] {
    assert_true(@quic.quic_decode_frames(bytes) is Err(Protocol(0x07L, _)))
  }
  assert_true(
    @quic.quic_decode_frames(b"\x18\x00\x00\x04") is Err(NeedMoreInput),
  )
}

///|
test "quic frame codec: malformed ranges and oversized values fail" {
  let high = @quic.QUIC_MAX_VARINT + 1L
  for
    frame in [
      @quic.QuicFrame::MaxData(high),
      StopSending(0L, high),
      ConnectionClose(true, 0L, high, b""),
    ] {
    assert_true(@quic.quic_encode_frames([Ping, frame]) is Err(VarIntOverflow))
  }
  let largest = @quic.QUIC_MAX_VARINT
  let end : @quic.StreamFrame = {
    stream_id: 0L,
    offset: largest,
    data: b"x",
    fin: false,
  }
  assert_true(@quic.quic_encode_frame(Stream(end)) is Err(VarIntOverflow))
  assert_true(
    @quic.quic_encode_frame(Crypto(largest, b"x")) is Err(VarIntOverflow),
  )
  assert_true(@quic.StreamFrame::new(0L, largest, b"", true) is Ok(_))
  let boundary = @quic.quic_encode_frame(MaxData(largest)).unwrap()
  assert_eq(@quic.quic_decode_frames(boundary).unwrap(), [MaxData(largest)])
}

///|
test "quic frame codec: ACK ranges and ECN counters must fit their wire representation" {
  let bad_ack : @quic.AckFrame = {
    largest_acknowledged: 10L,
    ack_delay: 0L,
    ranges: [{ largest: 10L, smallest: -1L, }],
    ecn_counts: None,
  }
  assert_true(@quic.quic_encode_frame(Ack(bad_ack)) is Err(InvalidFrame(_)))
  let ranges : Array[@quic.AckRange] = [{ largest: 2L, smallest: 2L, }]
  let ack = @quic.AckFrame::new(2L, 0L, ranges).unwrap()
  ranges.push({ largest: 1L, smallest: 0L, })
  assert_true(@quic.quic_encode_frame(Ack(ack)) is Err(InvalidFrame(_)))
  assert_true(@quic.AckFrame::new(2L, 0L, ranges) is Err(InvalidFrame(_)))
  let many = @quic.AckFrame::new(4L, 0L, [
    { largest: 4L, smallest: 4L, },
    { largest: 2L, smallest: 2L, },
    { largest: 0L, smallest: 0L, },
  ]).unwrap()
  let one_gap = { ..@quic.QuicLimits::defaults(), max_ack_ranges: 1, }
  assert_true(
    @quic.quic_encode_frame(Ack(many), limits=one_gap)
    is Err(LimitExceeded(_, 1)),
  )
  assert_true(
    @quic.AckFrame::new(
      10L,
      0L,
      [{ largest: 10L, smallest: 1L, }],
      ecn_counts=Some((@quic.QUIC_MAX_VARINT + 1L, 0L, 1L)),
    )
    is Err(VarIntOverflow),
  )
  assert_true(
    @quic.AckFrame::new(10L, 0L, [{ largest: 9L, smallest: 9L, }])
    is Err(InvalidFrame(_)),
  )
}

///|
test "quic frame codec: the payload limit includes every frame and its headers" {
  let two = { ..@quic.QuicLimits::defaults(), max_frame_payload: 2, }
  assert_eq(
    @quic.quic_encode_frames([Ping, Padding], limits=two),
    Ok(b"\x01\x00"),
  )
  assert_true(
    @quic.quic_encode_frames([Ping, Padding, Ping], limits=two)
    is Err(LimitExceeded(_, 2)),
  )
  assert_true(
    @quic.quic_encode_frames([], limits={ ..two, max_packet_size: 0, })
    is Err(_),
  )
  assert_true(
    @quic.quic_decode_frames(b"", limits={ ..two, max_packet_size: 0, })
    is Err(LimitExceeded("max_packet_size", 0)),
  )
  assert_true(
    @quic.quic_decode_frames(b"\x01\x00\x01", limits=two)
    is Err(LimitExceeded("frame payload", 2)),
  )
  assert_true(
    @quic.quic_encode_frame(Datagram(b"x"), limits=two)
    is Err(LimitExceeded(_, 2)),
  )
}
