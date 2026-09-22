///|
test "quic: varints use canonical boundaries and reject truncation" {
  for
    value in [
      0L,
      63L,
      64L,
      16383L,
      16384L,
      1073741823L,
      1073741824L,
      @quic.QUIC_MAX_VARINT,
    ] {
    let encoded = @quic.QuicVarInt::new(value).unwrap().encode()
    let (decoded, used) = @quic.quic_decode_varint(encoded).unwrap()
    assert_eq(decoded.value(), value)
    assert_eq(used, encoded.length())
  }
  assert_true(@quic.quic_decode_varint(b"\x40") is Err(_))
  assert_eq(
    @quic.quic_decode_varint(b"\xc0\x00\x00\x00\x00\x00\x00\x01").unwrap().0.value(),
    1L,
  )
  assert_true(
    @quic.quic_decode_varint(
      b"\xc0\x00\x00\x00\x00\x00\x00\x01",
      canonical=true,
    )
    is Err(NonCanonicalVarInt),
  )
  assert_true(@quic.QuicVarInt::new(-1L) is Err(_))
}

///|
test "quic: packet header parser handles initial and short forms" {
  let initial = Bytes::from_array([
    0xc3, 0, 0, 0, 1, 4, 1, 2, 3, 4, 4, 5, 6, 7, 8, 0, 5, 0, 0, 0, 1,
  ])
  assert_true(@quic.quic_decode_packet_header(initial) is Ok(_))
  let short = Bytes::from_array([0x40, 1, 2, 3, 4, 0x01])
  let (header, used) = @quic.quic_decode_packet_header(
    short,
    short_destination_length=4,
  ).unwrap()
  assert_eq(used, 6)
  assert_true(header is Short(_))
  assert_true(
    @quic.quic_decode_packet_header(short, short_destination_length=5) is Err(_),
  )
}

///|
test "quic: ACK ranges and stream frames enforce flow limits" {
  let range = @quic.AckRange::new(10L, 8L).unwrap()
  let ack = @quic.AckFrame::new(10L, 0L, [range]).unwrap()
  let connection = @quic.QuicConnection::new(Client).unwrap()
  connection.establish().unwrap()
  let stream = connection.open_bidirectional_stream().unwrap()
  let frame = connection.send_stream(stream, b"hello", true).unwrap()
  assert_true(frame is Stream(_))
  assert_true(connection.send_stream(stream, b"again", false) is Err(_))
  assert_eq(ack.largest_acknowledged(), 10L)
}

///|
test "quic: application streams are unavailable before establishment" {
  let connection = @quic.QuicConnection::new(Client).unwrap()
  assert_true(connection.open_bidirectional_stream() is Err(Unsupported(_)))
  connection.establish().unwrap()
  let stream = connection.open_bidirectional_stream().unwrap()
  assert_true(connection.send_stream(stream, b"ok", true) is Ok(_))
}

///|
test "quic: frame parser rejects ACK underflow and unknown types" {
  let bad = Bytes::from_array([2, 0, 0, 0, 1, 0])
  assert_true(@quic.quic_decode_frames(bad) is Err(_))
  assert_true(
    @quic.quic_decode_frames(Bytes::from_array([0x40, 0xaa])) is Err(_),
  )
}

///|
test "quic: transport parameters and packet protection are explicit" {
  assert_eq(@quic.QuicTransportParams::defaults().validate(), Ok(()))
  let defaults = @quic.QuicTransportParams::defaults()
  let bad : @quic.QuicTransportParams = {
    max_idle_timeout: defaults.max_idle_timeout,
    max_udp_payload_size: 1199,
    initial_max_data: defaults.initial_max_data,
    initial_max_stream_data_bidi_local: defaults.initial_max_stream_data_bidi_local,
    initial_max_stream_data_bidi_remote: defaults.initial_max_stream_data_bidi_remote,
    initial_max_stream_data_uni: defaults.initial_max_stream_data_uni,
    initial_max_streams_bidi: defaults.initial_max_streams_bidi,
    initial_max_streams_uni: defaults.initial_max_streams_uni,
    active_connection_id_limit: defaults.active_connection_id_limit,
    disable_active_migration: defaults.disable_active_migration,
  }
  assert_true(bad.validate() is Err(_))
  assert_true(@quic.quic_protect_packet(b"packet") is Err(Unsupported(_)))
}

///|
test "quic: STREAM data is reordered, deduplicated, and FIN waits for gaps" {
  let connection = @quic.QuicConnection::new(Client).unwrap()
  let tail = @quic.StreamFrame::new(1L, 3L, b"lo", true).unwrap()
  assert_eq(connection.receive_frame(Stream(tail)).unwrap(), [])
  let head = @quic.StreamFrame::new(1L, 0L, b"hel", false).unwrap()
  assert_eq(connection.receive_frame(Stream(head)).unwrap(), [
    StreamData(1L, b"hello", true),
  ])
  let duplicate = @quic.StreamFrame::new(1L, 2L, b"llo", true).unwrap()
  assert_eq(connection.receive_frame(Stream(duplicate)).unwrap(), [])
  let conflicting = @quic.StreamFrame::new(1L, 4L, b"X", true).unwrap()
  assert_true(connection.receive_frame(Stream(conflicting)) is Err(Protocol(_)))
}

///|
test "quic: empty STREAM FIN is delivered once" {
  let connection = @quic.QuicConnection::new(Client).unwrap()
  let fin = @quic.StreamFrame::new(1L, 0L, b"", true).unwrap()
  assert_eq(connection.receive_frame(Stream(fin)).unwrap(), [
    StreamData(1L, b"", true),
  ])
  assert_eq(connection.receive_frame(Stream(fin)).unwrap(), [])
}

///|
test "quic: local resource ceilings cap negotiated flow-control windows" {
  let limits : @quic.QuicLimits = {
    ..@quic.QuicLimits::defaults(),
    max_connection_data: 4L,
    max_stream_data: 8L,
  }
  let params : @quic.QuicTransportParams = {
    ..@quic.QuicTransportParams::defaults(),
    initial_max_data: 100L,
    initial_max_stream_data_bidi_local: 100L,
    initial_max_stream_data_bidi_remote: 100L,
  }
  let sender = @quic.QuicConnection::new(
    Client,
    limits~,
    transport_params=params,
  ).unwrap()
  sender.establish().unwrap()
  let local_stream = sender.open_bidirectional_stream().unwrap()
  ignore(sender.send_stream(local_stream, b"1234", false).unwrap())
  assert_true(
    sender.send_stream(local_stream, b"5", false) is Err(FlowControl(0L, _)),
  )
  let receiver = @quic.QuicConnection::new(
    Client,
    limits~,
    transport_params=params,
  ).unwrap()
  let oversized = @quic.StreamFrame::new(1L, 0L, b"12345", false).unwrap()
  assert_true(
    receiver.receive_frame(Stream(oversized)) is Err(FlowControl(0L, _)),
  )
}

///|
test "quic: non-increasing MAX frames are ignored and increases stay capped" {
  let limits : @quic.QuicLimits = {
    ..@quic.QuicLimits::defaults(),
    max_connection_data: 4L,
    max_stream_data: 4L,
  }
  let params : @quic.QuicTransportParams = {
    ..@quic.QuicTransportParams::defaults(),
    initial_max_data: 2L,
    initial_max_stream_data_bidi_remote: 2L,
  }
  let connection = @quic.QuicConnection::new(
    Client,
    limits~,
    transport_params=params,
  ).unwrap()
  connection.establish().unwrap()
  let stream = connection.open_bidirectional_stream().unwrap()
  ignore(connection.send_stream(stream, b"12", false).unwrap())
  assert_eq(connection.receive_frame(MaxData(1L)).unwrap(), [])
  assert_eq(connection.receive_frame(MaxStreamData(stream, 1L)).unwrap(), [])
  assert_eq(connection.receive_frame(MaxData(100L)).unwrap(), [])
  assert_eq(connection.receive_frame(MaxStreamData(stream, 100L)).unwrap(), [])
  ignore(connection.send_stream(stream, b"34", false).unwrap())
  assert_true(
    connection.send_stream(stream, b"5", false) is Err(FlowControl(_, _)),
  )
}
