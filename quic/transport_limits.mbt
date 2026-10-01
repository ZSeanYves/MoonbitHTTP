///|
pub(all) struct QuicTransportParams {
  max_idle_timeout : Int64
  max_udp_payload_size : Int
  initial_max_data : Int64
  initial_max_stream_data_bidi_local : Int64
  initial_max_stream_data_bidi_remote : Int64
  initial_max_stream_data_uni : Int64
  initial_max_streams_bidi : Int64
  initial_max_streams_uni : Int64
  active_connection_id_limit : Int64
  disable_active_migration : Bool
} derive(Eq, Debug)

///|
pub fn QuicTransportParams::defaults() -> QuicTransportParams {
  {
    max_idle_timeout: 30000L,
    max_udp_payload_size: 1200,
    initial_max_data: 16 * 1024 * 1024L,
    initial_max_stream_data_bidi_local: 1024 * 1024L,
    initial_max_stream_data_bidi_remote: 1024 * 1024L,
    initial_max_stream_data_uni: 1024 * 1024L,
    initial_max_streams_bidi: 100L,
    initial_max_streams_uni: 3L,
    active_connection_id_limit: 2L,
    disable_active_migration: false,
  }
}

///|
pub fn QuicTransportParams::validate(
  self : QuicTransportParams,
) -> Result[Unit, QuicError] {
  if self.max_udp_payload_size < 1200 ||
    self.max_udp_payload_size > QUIC_MAX_PACKET_SIZE {
    return Err(InvalidTransportParameter("max_udp_payload_size"))
  }
  let values : Array[(String, Int64)] = [
    ("max_idle_timeout", self.max_idle_timeout),
    ("initial_max_data", self.initial_max_data),
    (
      "initial_max_stream_data_bidi_local",
      self.initial_max_stream_data_bidi_local,
    ),
    (
      "initial_max_stream_data_bidi_remote",
      self.initial_max_stream_data_bidi_remote,
    ),
    ("initial_max_stream_data_uni", self.initial_max_stream_data_uni),
    ("initial_max_streams_bidi", self.initial_max_streams_bidi),
    ("initial_max_streams_uni", self.initial_max_streams_uni),
  ]
  for entry in values {
    let (name, value) = entry
    if value < 0L || value > QUIC_MAX_VARINT {
      return Err(InvalidTransportParameter(name))
    }
  }
  if self.active_connection_id_limit < 2L ||
    self.active_connection_id_limit > QUIC_MAX_VARINT {
    return Err(InvalidTransportParameter("active_connection_id_limit"))
  }
  if self.initial_max_streams_bidi > 0x1000000000000000L ||
    self.initial_max_streams_uni > 0x1000000000000000L {
    return Err(InvalidTransportParameter("initial_max_streams exceeds 2^60"))
  }
  Ok(())
}
