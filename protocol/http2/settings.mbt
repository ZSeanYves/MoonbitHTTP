///|
priv struct H2Settings {
  mut enable_push : Bool
  mut max_concurrent_streams : Int
  mut initial_window_size : Int
  mut max_frame_size : Int
}

///|
fn H2Settings::defaults() -> H2Settings {
  {
    enable_push: true,
    max_concurrent_streams: 100,
    initial_window_size: 65535,
    max_frame_size: H2_DEFAULT_MAX_FRAME_SIZE,
  }
}

///|
fn H2Settings::from_limits(limits : @types.Limits) -> H2Settings {
  {
    enable_push: true,
    max_concurrent_streams: limits.max_streams.min(
      limits.max_concurrent_requests,
    ),
    initial_window_size: 65535,
    max_frame_size: H2_DEFAULT_MAX_FRAME_SIZE,
  }
}

///|
pub fn H2Connection::apply_settings_payload(
  self : H2Connection,
  payload : BytesView,
) -> Result[Array[H2Action], H2ProtocolError] {
  if payload.length() % 6 != 0 {
    return Err(
      ConnectionError(
        FrameSizeError,
        "HTTP2-Settings payload is not a multiple of 6",
      ),
    )
  }
  self.apply_settings_entries(payload.to_owned().to_array())
}

///|
/// Both the h2c HTTP2-Settings field and SETTINGS frames use the same entry
/// parser after their enclosing framing has checked the six-byte alignment.
fn H2Connection::apply_settings_entries(
  self : H2Connection,
  bytes : Array[Byte],
) -> Result[Array[H2Action], H2ProtocolError] {
  let actions : Array[H2Action] = []
  let mut offset = 0
  while offset < bytes.length() {
    let id = ((bytes[offset].to_int() & 0xff) << 8) |
      (bytes[offset + 1].to_int() & 0xff)
    let value = u32(bytes, offset + 2)
    match self.apply_setting(id, value) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    if id == 1 {
      // Values above Int::max_value are valid uint32 settings. The encoder
      // still obeys its local allocation ceiling, so no signed cast escapes.
      let size = if value < 0 {
        self.limits.max_dynamic_table_bytes
      } else {
        value.min(self.limits.max_dynamic_table_bytes)
      }
      actions.push(PeerHeaderTableSize(size))
    }
    offset += 6
  }
  Ok(actions)
}

///|
fn H2Connection::apply_setting(
  self : H2Connection,
  id : Int,
  value : Int,
) -> Result[Unit, H2ProtocolError] {
  match id {
    // The ordered PeerHeaderTableSize action updates the driver's encoder.
    1 => ()
    2 => {
      if self.role == Client {
        return Err(
          ConnectionError(
            ProtocolError,
            "server must not send SETTINGS_ENABLE_PUSH",
          ),
        )
      }
      if value != 0 && value != 1 {
        return Err(
          ConnectionError(ProtocolError, "SETTINGS_ENABLE_PUSH must be 0 or 1"),
        )
      }
      self.peer_settings.enable_push = value == 1
    }
    3 =>
      self.peer_settings.max_concurrent_streams = if value < 0 {
        self.limits.max_streams
      } else {
        value.min(self.limits.max_streams)
      }
    4 => {
      if value < 0 || value > 0x7fffffff {
        return Err(
          ConnectionError(FlowControlError, "invalid initial window size"),
        )
      }
      let delta = value - self.peer_settings.initial_window_size
      // Check every stream before mutating any stream so a bad SETTINGS
      // update cannot leave a partially changed connection.
      for stream in self.streams.values() {
        if (
            delta > 0 &&
            (
              delta > H2_MAX_WINDOW ||
              stream.send_window > H2_MAX_WINDOW - delta
            )
          ) ||
          (
            delta < 0 &&
            (
              delta < H2_MIN_WINDOW ||
              stream.send_window < H2_MIN_WINDOW - delta
            )
          ) {
          return Err(
            ConnectionError(
              FlowControlError,
              "stream window overflow after SETTINGS",
            ),
          )
        }
      }
      for stream in self.streams.values() {
        stream.send_window += delta
      }
      self.peer_settings.initial_window_size = value
    }
    5 => {
      if value < 16384 || value > 16777215 {
        return Err(ConnectionError(ProtocolError, "invalid max frame size"))
      }
      self.peer_settings.max_frame_size = value
    }
    // SETTINGS_MAX_HEADER_LIST_SIZE is advisory; local header-list ceilings
    // are enforced by HpackContext and the protocol driver's Limits.
    6 => ()
    _ => ()
  }
  Ok(())
}
