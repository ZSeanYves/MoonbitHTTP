///|
pub(all) enum H3UnidirectionalStream {
  H3ControlStream
  H3PushStream(Int64)
  H3QpackEncoderStream
  H3QpackDecoderStream
  H3UnknownStream(Int64)
} derive(Eq, Debug)

///|
pub(all) struct H3Settings {
  qpack_max_table_capacity : Int64
  max_field_section_size : Int64
  qpack_blocked_streams : Int64
  enable_connect_protocol : Bool
  unknown : Array[H3Setting]
} derive(Eq, Debug)

///|
pub fn H3Settings::defaults() -> H3Settings {
  {
    qpack_max_table_capacity: 0L,
    max_field_section_size: @quic.QUIC_MAX_VARINT,
    qpack_blocked_streams: 0L,
    enable_connect_protocol: false,
    unknown: [],
  }
}

///|
pub fn Http3Connection::peer_settings(self : Http3Connection) -> H3Settings {
  self.peer_settings
}

///|
pub fn Http3Connection::local_settings_frame(
  self : Http3Connection,
  enable_connect_protocol? : Bool = false,
) -> Http3Frame {
  // RFC 9220 / RFC 8441: only the server can enable Extended CONNECT. Keep
  // this advertised capability monotonic if the settings frame is regenerated.
  if self.role == H3Server && enable_connect_protocol {
    self.local_enable_connect_protocol = true
  }
  let settings : Array[H3Setting] = [
    {
      id: H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY,
      value: self.qpack_limits.max_table_capacity.to_int64(),
    },
    {
      id: H3_SETTINGS_MAX_FIELD_SECTION_SIZE,
      value: self.qpack_limits.max_decoded_field_section_bytes.to_int64(),
    },
    {
      id: H3_SETTINGS_QPACK_BLOCKED_STREAMS,
      value: self.qpack_limits.max_blocked_streams.to_int64(),
    },
  ]
  if self.local_enable_connect_protocol {
    settings.push({ id: H3_SETTINGS_ENABLE_CONNECT_PROTOCOL, value: 1L, })
  }
  H3SettingsFrame(settings)
}

///|
fn h3_remote_initiated(role : H3Role, stream_id : Int64) -> Bool {
  if stream_id < 0L {
    false
  } else if role == H3Client {
    (stream_id & 1L) == 1L
  } else {
    (stream_id & 1L) == 0L
  }
}

///|
fn h3_unidirectional(stream_id : Int64) -> Bool {
  stream_id >= 0L && (stream_id & 2L) != 0L
}

///|
pub fn Http3Connection::register_remote_unidirectional(
  self : Http3Connection,
  stream_id : Int64,
  prefix : BytesView,
) -> Result[(H3UnidirectionalStream, Int), Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !h3_unidirectional(stream_id) || !h3_remote_initiated(self.role, stream_id) {
    return Err(
      Http3ConnectionError(
        H3StreamCreationError,
        "invalid remote unidirectional stream ID",
      ),
    )
  }
  let (stream_type, type_used) = match h3_decode_varint(prefix) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  if stream_type == H3_STREAM_CONTROL {
    if self.remote_control_stream is Some(_) {
      return Err(
        Http3ConnectionError(
          H3StreamCreationError,
          "duplicate HTTP/3 control stream",
        ),
      )
    }
    self.remote_control_stream = Some(stream_id)
    Ok((H3ControlStream, type_used))
  } else if stream_type == H3_STREAM_QPACK_ENCODER {
    if self.remote_qpack_encoder_stream is Some(_) {
      return Err(
        Http3ConnectionError(
          H3StreamCreationError,
          "duplicate QPACK encoder stream",
        ),
      )
    }
    self.remote_qpack_encoder_stream = Some(stream_id)
    Ok((H3QpackEncoderStream, type_used))
  } else if stream_type == H3_STREAM_QPACK_DECODER {
    if self.remote_qpack_decoder_stream is Some(_) {
      return Err(
        Http3ConnectionError(
          H3StreamCreationError,
          "duplicate QPACK decoder stream",
        ),
      )
    }
    self.remote_qpack_decoder_stream = Some(stream_id)
    Ok((H3QpackDecoderStream, type_used))
  } else if stream_type == H3_STREAM_PUSH {
    if self.role == H3Server {
      return Err(
        Http3ConnectionError(
          H3StreamCreationError,
          "client created a push stream",
        ),
      )
    }
    let (push_id, push_used) = match h3_decode_varint(prefix[type_used:]) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    Ok((H3PushStream(push_id), type_used + push_used))
  } else {
    Ok((H3UnknownStream(stream_type), type_used))
  }
}

///|
pub fn Http3Connection::remote_unidirectional_closed(
  self : Http3Connection,
  stream_id : Int64,
) -> Result[Unit, Http3Error] {
  if self.remote_control_stream == Some(stream_id) ||
    self.remote_qpack_encoder_stream == Some(stream_id) ||
    self.remote_qpack_decoder_stream == Some(stream_id) {
    let error = Http3ConnectionError(
      H3ClosedCriticalStream,
      "peer closed a critical HTTP/3 stream",
    )
    self.failure = Some(error)
    return Err(error)
  }
  Ok(())
}

///|
fn h3_apply_settings(
  settings : Array[H3Setting],
) -> Result[H3Settings, Http3Error] {
  let mut result = H3Settings::defaults()
  let unknown : Array[H3Setting] = []
  for setting in settings {
    if setting.id == H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY {
      result = { ..result, qpack_max_table_capacity: setting.value, }
    } else if setting.id == H3_SETTINGS_MAX_FIELD_SECTION_SIZE {
      result = { ..result, max_field_section_size: setting.value, }
    } else if setting.id == H3_SETTINGS_QPACK_BLOCKED_STREAMS {
      result = { ..result, qpack_blocked_streams: setting.value, }
    } else if setting.id == H3_SETTINGS_ENABLE_CONNECT_PROTOCOL {
      if setting.value != 0L && setting.value != 1L {
        return Err(
          Http3ConnectionError(
            H3SettingsError,
            "SETTINGS_ENABLE_CONNECT_PROTOCOL must be 0 or 1",
          ),
        )
      }
      result = { ..result, enable_connect_protocol: setting.value == 1L, }
    } else {
      unknown.push(setting)
    }
  }
  Ok({ ..result, unknown, })
}

///|
pub fn Http3Connection::receive_control_frame(
  self : Http3Connection,
  frame : Http3Frame,
) -> Result[Array[H3Action], Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.control_received_frame {
    self.control_received_frame = true
    if !(frame is H3SettingsFrame(_)) {
      let error = Http3ConnectionError(
        H3MissingSettings,
        "SETTINGS is not the first control-stream frame",
      )
      self.failure = Some(error)
      return Err(error)
    }
  }
  let actions : Array[H3Action] = []
  match frame {
    H3SettingsFrame(values) => {
      if self.settings_received {
        let error = Http3ConnectionError(
          H3FrameUnexpected,
          "duplicate SETTINGS frame",
        )
        self.failure = Some(error)
        return Err(error)
      }
      let settings = match h3_apply_settings(values) {
        Ok(result) => result
        Err(error) => {
          self.failure = Some(error)
          return Err(error)
        }
      }
      self.settings_received = true
      self.peer_settings = settings
      actions.push(H3PeerSettingsReceived(settings))
      let selected_capacity = settings.qpack_max_table_capacity
        .min(self.qpack_limits.max_table_capacity.to_int64())
        .to_int()
      if selected_capacity > 0 {
        match self.encoder.set_capacity(selected_capacity) {
          Ok(instruction) =>
            actions.push(H3SendQpackEncoderInstruction(instruction))
          Err(error) => return Err(error)
        }
      }
    }
    H3CancelPush(push_id) => actions.push(H3CancelPushReceived(push_id))
    H3MaxPushId(push_id) => {
      if self.role != H3Server {
        return Err(
          Http3ConnectionError(H3FrameUnexpected, "server sent MAX_PUSH_ID"),
        )
      }
      if self.max_push_id is Some(previous) && push_id < previous {
        return Err(Http3ConnectionError(H3IdError, "MAX_PUSH_ID decreased"))
      }
      self.max_push_id = Some(push_id)
      actions.push(H3MaxPushIdReceived(push_id))
    }
    H3Goaway(id) => {
      if (id & 3L) != 0L {
        return Err(
          Http3ConnectionError(
            H3IdError,
            "server GOAWAY ID is not a client request stream",
          ),
        )
      }
      if self.goaway_id is Some(previous) && id > previous {
        return Err(
          Http3ConnectionError(H3IdError, "GOAWAY identifier increased"),
        )
      }
      self.goaway_id = Some(id)
      actions.push(H3GoawayReceived(id))
    }
    H3Unknown(typ, _) => actions.push(H3UnknownFrameIgnored(typ))
    _ =>
      return Err(
        Http3ConnectionError(
          H3FrameUnexpected,
          "frame type is not permitted on the HTTP/3 control stream",
        ),
      )
  }
  Ok(actions)
}
