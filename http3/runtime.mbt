///|
pub(all) enum H3Role {
  H3Client
  H3Server
} derive(Eq, Debug)

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
pub(all) enum H3IncomingMessage {
  H3IncomingRequest
  H3IncomingResponse(String?)
} derive(Eq, Debug)

///|
pub(all) enum H3MessagePhase {
  H3WaitingHeaders
  H3OpenBody
  H3TrailersReceived
  H3MessageComplete
  H3MessageCancelled
} derive(Eq, Debug)

///|
pub(all) enum H3FieldSectionKind {
  H3RequestFields
  H3ResponseFields
  H3TrailerFields
  H3PushPromiseFields
} derive(Eq, Debug)

///|
pub(all) struct H3MessageMetadata {
  content_length : Int64?
  http_method : String?
  status : Int?
  informational : Bool
  body_forbidden : Bool
} derive(Eq, Debug)

///|
pub(all) enum H3Action {
  H3PeerSettingsReceived(H3Settings)
  H3SendQpackEncoderInstruction(Bytes)
  H3SendQpackDecoderInstruction(Bytes)
  H3HeadersReceived(Int64, Array[QpackField], Bool, Bool)
  H3DataReceived(Int64, Bytes)
  H3PushPromiseReceived(Int64, Int64, Array[QpackField])
  H3CancelPushReceived(Int64)
  H3MaxPushIdReceived(Int64)
  H3GoawayReceived(Int64)
  H3UnknownFrameIgnored(Int64)
} derive(Eq, Debug)

///|
fn h3_ascii_equal_fold(value : BytesView, expected : BytesView) -> Bool {
  if value.length() != expected.length() {
    return false
  }
  for index in 0..<value.length() {
    let byte = value[index]
    let folded = if byte >= b'A' && byte <= b'Z' {
      (byte.to_int() + 32).to_byte()
    } else {
      byte
    }
    if folded != expected[index] {
      return false
    }
  }
  true
}

///|
fn h3_connection_specific_field(name : String) -> Bool {
  name == "connection" ||
  name == "proxy-connection" ||
  name == "keep-alive" ||
  name == "transfer-encoding" ||
  name == "upgrade"
}

///|
fn h3_parse_decimal(value : BytesView) -> Result[Int64, Unit] {
  if value.is_empty() {
    return Err(())
  }
  let mut result = 0L
  for byte in value {
    if byte < b'0' || byte > b'9' {
      return Err(())
    }
    let digit = (byte.to_int() - 48).to_int64()
    if result > (@quic.QUIC_MAX_VARINT - digit) / 10L {
      return Err(())
    }
    result = result * 10L + digit
  }
  Ok(result)
}

///|
fn h3_content_length(
  stream_id : Int64,
  fields : Array[QpackField],
) -> Result[Int64?, Http3Error] {
  let mut expected : Int64? = None
  for field in fields {
    if field.name != "content-length" {
      continue
    }
    let value = field.value
    let mut start = 0
    while start <= value.length() {
      let mut end = start
      while end < value.length() && value[end] != b',' {
        end += 1
      }
      let mut item_start = start
      let mut item_end = end
      while item_start < item_end &&
            (value[item_start] == b' ' || value[item_start] == b'\t') {
        item_start += 1
      }
      while item_end > item_start &&
            (value[item_end - 1] == b' ' || value[item_end - 1] == b'\t') {
        item_end -= 1
      }
      let parsed = match h3_parse_decimal(value[item_start:item_end]) {
        Ok(result) => result
        Err(_) =>
          return Err(
            Http3StreamError(
              stream_id,
              H3MessageError,
              "invalid Content-Length",
            ),
          )
      }
      match expected {
        None => expected = Some(parsed)
        Some(previous) if previous == parsed => ()
        Some(_) =>
          return Err(
            Http3StreamError(
              stream_id,
              H3MessageError,
              "conflicting Content-Length",
            ),
          )
      }
      if end == value.length() {
        break
      }
      start = end + 1
    }
  }
  Ok(expected)
}

///|
fn h3_pseudo_text(
  stream_id : Int64,
  field : QpackField,
) -> Result[String, Http3Error] {
  Ok(@utf8.decode(field.value)) catch {
    _ =>
      Err(
        Http3StreamError(
          stream_id,
          H3MessageError,
          "pseudo-field value is not valid UTF-8",
        ),
      )
  }
}

///|
fn h3_regular_text(
  stream_id : Int64,
  field : QpackField,
) -> Result[String, Http3Error] {
  Ok(@utf8.decode(field.value)) catch {
    _ =>
      Err(
        Http3StreamError(
          stream_id,
          H3MessageError,
          "header value is not valid UTF-8",
        ),
      )
  }
}

///|
fn h3_has_pseudo(seen : Array[String], name : String) -> Bool {
  for value in seen {
    if value == name {
      return true
    }
  }
  false
}

///|
pub fn validate_http3_field_section(
  stream_id : Int64,
  fields : Array[QpackField],
  kind : H3FieldSectionKind,
  request_method? : String? = None,
) -> Result[H3MessageMetadata, Http3Error] {
  let seen_pseudo : Array[String] = []
  let mut saw_regular = false
  let mut method_field : String? = None
  let mut scheme : String? = None
  let mut authority : String? = None
  let mut path : String? = None
  let mut protocol : String? = None
  let mut status : Int? = None
  let mut host : String? = None
  for field in fields {
    match qpack_validate_field(field) {
      Ok(_) => ()
      Err(_) =>
        return Err(
          Http3StreamError(stream_id, H3MessageError, "invalid HTTP/3 field"),
        )
    }
    if field.name.has_prefix(":") {
      if kind == H3TrailerFields ||
        saw_regular ||
        h3_has_pseudo(seen_pseudo, field.name) {
        return Err(
          Http3StreamError(
            stream_id,
            H3MessageError,
            "invalid pseudo-field ordering or duplication",
          ),
        )
      }
      seen_pseudo.push(field.name)
      let value = match h3_pseudo_text(stream_id, field) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      match field.name {
        ":method" => method_field = Some(value)
        ":scheme" => scheme = Some(value)
        ":authority" => authority = Some(value)
        ":path" => path = Some(value)
        ":protocol" => protocol = Some(value)
        ":status" => {
          let bytes = field.value
          if bytes.length() != 3 {
            return Err(
              Http3StreamError(stream_id, H3MessageError, "invalid :status"),
            )
          }
          let parsed = match h3_parse_decimal(bytes) {
            Ok(result) if result >= 100L && result <= 999L => result.to_int()
            _ =>
              return Err(
                Http3StreamError(stream_id, H3MessageError, "invalid :status"),
              )
          }
          status = Some(parsed)
        }
        _ =>
          return Err(
            Http3StreamError(stream_id, H3MessageError, "unknown pseudo-field"),
          )
      }
    } else {
      saw_regular = true
      if h3_connection_specific_field(field.name) ||
        (field.name == "te" && !h3_ascii_equal_fold(field.value, b"trailers")) {
        return Err(
          Http3StreamError(
            stream_id,
            H3MessageError,
            "connection-specific field in HTTP/3",
          ),
        )
      }
      if kind == H3TrailerFields &&
        (
          field.name == "content-length" ||
          field.name == "host" ||
          field.name == "te" ||
          field.name == "trailer"
        ) {
        return Err(
          Http3StreamError(
            stream_id,
            H3MessageError,
            "forbidden HTTP/3 trailer field",
          ),
        )
      }
      if field.name == "host" {
        if host is Some(_) {
          return Err(
            Http3StreamError(stream_id, H3MessageError, "duplicate Host"),
          )
        }
        host = match h3_regular_text(stream_id, field) {
          Ok(value) => Some(value)
          Err(error) => return Err(error)
        }
      }
    }
  }
  let content_length = match h3_content_length(stream_id, fields) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  if kind == H3RequestFields || kind == H3PushPromiseFields {
    if status is Some(_) || method_field is None {
      return Err(
        Http3StreamError(
          stream_id,
          H3MessageError,
          "invalid request pseudo-fields",
        ),
      )
    }
    let method_value = match method_field {
      Some(value) => value
      None =>
        return Err(
          Http3StreamError(stream_id, H3MessageError, "missing :method"),
        )
    }
    let http_method = match @types.Method::parse(method_value) {
      Ok(value) => value
      Err(_) =>
        return Err(
          Http3StreamError(stream_id, H3MessageError, "invalid :method"),
        )
    }
    let parsed_authority = match authority {
      Some(value) =>
        match @types.Authority::parse_endpoint(value) {
          Ok(parsed) => parsed
          Err(_) =>
            return Err(
              Http3StreamError(stream_id, H3MessageError, "invalid :authority"),
            )
        }
      None =>
        return Err(
          Http3StreamError(stream_id, H3MessageError, "missing :authority"),
        )
    }
    match host {
      Some(value) => {
        let parsed_host = match @types.Authority::parse_endpoint(value) {
          Ok(parsed) => parsed
          Err(_) =>
            return Err(
              Http3StreamError(stream_id, H3MessageError, "invalid Host"),
            )
        }
        if parsed_host.host != parsed_authority.host ||
          parsed_host.port != parsed_authority.port ||
          parsed_host.ip_literal != parsed_authority.ip_literal {
          return Err(
            Http3StreamError(
              stream_id,
              H3MessageError,
              "Host/:authority mismatch",
            ),
          )
        }
      }
      None => ()
    }
    if method_value == "CONNECT" && protocol is None {
      if authority is None || scheme is Some(_) || path is Some(_) {
        return Err(
          Http3StreamError(
            stream_id,
            H3MessageError,
            "invalid CONNECT pseudo-fields",
          ),
        )
      }
    } else {
      if scheme is None || path is None || path == Some("") || authority is None {
        return Err(
          Http3StreamError(
            stream_id,
            H3MessageError,
            "required request pseudo-field is missing",
          ),
        )
      }
      let scheme_value = match scheme {
        Some(value) => value
        None => ""
      }
      if scheme_value != "http" && scheme_value != "https" {
        return Err(
          Http3StreamError(stream_id, H3MessageError, "invalid :scheme"),
        )
      }
      if protocol is Some(_) && method_value != "CONNECT" {
        return Err(
          Http3StreamError(
            stream_id,
            H3MessageError,
            ":protocol requires CONNECT",
          ),
        )
      }
      let path_value = match path {
        Some(value) => value
        None => ""
      }
      match @types.Uri::parse_request_target(path_value, http_method) {
        Ok(uri) if uri.form == OriginForm || uri.form == AsteriskForm => ()
        _ =>
          return Err(
            Http3StreamError(stream_id, H3MessageError, "invalid :path"),
          )
      }
    }
    return Ok({
      content_length,
      http_method: method_field,
      status: None,
      informational: false,
      body_forbidden: false,
    })
  }
  if kind == H3ResponseFields {
    if method_field is Some(_) ||
      scheme is Some(_) ||
      authority is Some(_) ||
      path is Some(_) ||
      protocol is Some(_) ||
      status is None {
      return Err(
        Http3StreamError(
          stream_id,
          H3MessageError,
          "invalid response pseudo-fields",
        ),
      )
    }
    let status_value = match status {
      Some(value) => value
      None =>
        return Err(
          Http3StreamError(stream_id, H3MessageError, "missing :status"),
        )
    }
    if status_value == 101 {
      return Err(
        Http3StreamError(stream_id, H3MessageError, "HTTP/3 forbids status 101"),
      )
    }
    if ((status_value >= 100 && status_value < 200) || status_value == 204) &&
      content_length is Some(_) {
      return Err(
        Http3StreamError(
          stream_id,
          H3MessageError,
          "Content-Length is forbidden for this status",
        ),
      )
    }
    let informational = status_value >= 100 && status_value < 200
    return Ok({
      content_length,
      http_method: None,
      status,
      informational,
      body_forbidden: informational ||
      status_value == 204 ||
      status_value == 304 ||
      request_method == Some("HEAD"),
    })
  }
  Ok({
    content_length: None,
    http_method: None,
    status: None,
    informational: false,
    body_forbidden: false,
  })
}

///|
pub struct H3RequestStreamState {
  id : Int64
  incoming : H3IncomingMessage
  mut phase : H3MessagePhase
  mut expected_content_length : Int64?
  mut received_content_length : Int64
  mut body_forbidden : Bool
}

///|
fn H3RequestStreamState::new(
  id : Int64,
  incoming : H3IncomingMessage,
) -> H3RequestStreamState {
  {
    id,
    incoming,
    phase: H3WaitingHeaders,
    expected_content_length: None,
    received_content_length: 0L,
    body_forbidden: false,
  }
}

///|
pub struct Http3Connection {
  role : H3Role
  limits : @types.Limits
  qpack_limits : QpackLimits
  decoder : QpackDecoder
  encoder : QpackEncoder
  streams : Map[Int64, H3RequestStreamState]
  mut remote_control_stream : Int64?
  mut remote_qpack_encoder_stream : Int64?
  mut remote_qpack_decoder_stream : Int64?
  mut control_received_frame : Bool
  mut settings_received : Bool
  mut peer_settings : H3Settings
  mut goaway_id : Int64?
  mut max_push_id : Int64?
  mut next_request_stream_id : Int64
  mut failure : Http3Error?
}

///|
pub fn Http3Connection::new(
  role : H3Role,
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : QpackLimits = QpackLimits::defaults(),
) -> Result[Http3Connection, Http3Error] {
  match limits.validate() {
    Ok(_) => ()
    Err(_) => return Err(Http3LimitExceeded("shared HTTP limits", 0))
  }
  match qpack_limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if qpack_limits.max_table_capacity > limits.max_dynamic_table_bytes ||
    qpack_limits.max_field_count > limits.max_header_count ||
    qpack_limits.max_decoded_field_section_bytes > limits.max_header_bytes ||
    qpack_limits.max_encoded_field_section_bytes > limits.max_header_bytes ||
    qpack_limits.max_instruction_buffer_bytes > limits.max_buffer_bytes {
    return Err(
      Http3LimitExceeded(
        "QPACK limits exceed shared HTTP limits",
        limits.max_buffer_bytes,
      ),
    )
  }
  let decoder = match QpackDecoder::new(limits=qpack_limits) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  let encoder = match QpackEncoder::new(limits=qpack_limits) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  Ok({
    role,
    limits,
    qpack_limits,
    decoder,
    encoder,
    streams: Map([]),
    remote_control_stream: None,
    remote_qpack_encoder_stream: None,
    remote_qpack_decoder_stream: None,
    control_received_frame: false,
    settings_received: false,
    peer_settings: H3Settings::defaults(),
    goaway_id: None,
    max_push_id: None,
    next_request_stream_id: 0L,
    failure: None,
  })
}

///|
pub fn Http3Connection::peer_settings(self : Http3Connection) -> H3Settings {
  self.peer_settings
}

///|
pub fn Http3Connection::qpack_decoder(self : Http3Connection) -> QpackDecoder {
  self.decoder
}

///|
pub fn Http3Connection::qpack_encoder(self : Http3Connection) -> QpackEncoder {
  self.encoder
}

///|
pub fn Http3Connection::local_settings_frame(
  self : Http3Connection,
  enable_connect_protocol? : Bool = false,
) -> Http3Frame {
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
  if enable_connect_protocol {
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

///|
pub fn Http3Connection::open_request_stream(
  self : Http3Connection,
  request_method? : String? = None,
) -> Result[Int64, Http3Error] {
  if self.role != H3Client {
    return Err(
      Http3ConnectionError(
        H3StreamCreationError,
        "servers cannot initiate request streams",
      ),
    )
  }
  if self.goaway_id is Some(limit) && self.next_request_stream_id >= limit {
    return Err(
      Http3StreamError(
        self.next_request_stream_id,
        H3RequestRejected,
        "request rejected by GOAWAY",
      ),
    )
  }
  if self.streams.length() >= self.limits.max_streams {
    return Err(
      Http3LimitExceeded("HTTP/3 request streams", self.limits.max_streams),
    )
  }
  if self.next_request_stream_id > @quic.QUIC_MAX_VARINT - 4L {
    return Err(
      Http3ConnectionError(
        H3StreamCreationError,
        "request stream IDs are exhausted",
      ),
    )
  }
  let id = self.next_request_stream_id
  self.next_request_stream_id += 4L
  self.streams.set(
    id,
    H3RequestStreamState::new(id, H3IncomingResponse(request_method)),
  )
  Ok(id)
}

///|
pub fn Http3Connection::accept_request_stream(
  self : Http3Connection,
  stream_id : Int64,
) -> Result[Unit, Http3Error] {
  if self.role != H3Server || stream_id < 0L || (stream_id & 3L) != 0L {
    return Err(
      Http3ConnectionError(
        H3StreamCreationError,
        "invalid incoming request stream",
      ),
    )
  }
  if self.streams.get(stream_id) is Some(_) {
    return Err(
      Http3ConnectionError(H3StreamCreationError, "duplicate request stream"),
    )
  }
  if self.streams.length() >= self.limits.max_streams {
    return Err(
      Http3LimitExceeded("HTTP/3 request streams", self.limits.max_streams),
    )
  }
  self.streams.set(
    stream_id,
    H3RequestStreamState::new(stream_id, H3IncomingRequest),
  )
  Ok(())
}

///|
fn H3RequestStreamState::receive_headers(
  self : H3RequestStreamState,
  fields : Array[QpackField],
) -> Result[(Bool, Bool), Http3Error] {
  if self.phase == H3WaitingHeaders {
    let kind = match self.incoming {
      H3IncomingRequest => H3RequestFields
      H3IncomingResponse(_) => H3ResponseFields
    }
    let request_method = match self.incoming {
      H3IncomingResponse(value) => value
      _ => None
    }
    let metadata = match
      validate_http3_field_section(self.id, fields, kind, request_method~) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    if metadata.informational {
      if self.incoming is H3IncomingRequest {
        return Err(
          Http3StreamError(
            self.id,
            H3MessageError,
            "request headers cannot carry an informational status",
          ),
        )
      }
      return Ok((false, true))
    }
    self.phase = H3OpenBody
    self.expected_content_length = metadata.content_length
    self.body_forbidden = metadata.body_forbidden
    Ok((false, false))
  } else if self.phase == H3OpenBody {
    match validate_http3_field_section(self.id, fields, H3TrailerFields) {
      Ok(_) => {
        self.phase = H3TrailersReceived
        Ok((true, false))
      }
      Err(error) => Err(error)
    }
  } else {
    Err(
      Http3StreamError(
        self.id,
        H3FrameUnexpected,
        "HEADERS received after trailers or completion",
      ),
    )
  }
}

///|
fn H3RequestStreamState::receive_data(
  self : H3RequestStreamState,
  data : Bytes,
  max_body_bytes : Int,
) -> Result[Unit, Http3Error] {
  if self.phase != H3OpenBody {
    return Err(
      Http3StreamError(
        self.id,
        H3FrameUnexpected,
        "DATA received outside message body",
      ),
    )
  }
  if self.body_forbidden && !data.is_empty() {
    return Err(
      Http3StreamError(
        self.id,
        H3MessageError,
        "DATA is forbidden for this response",
      ),
    )
  }
  let length = data.length().to_int64()
  if self.received_content_length > max_body_bytes.to_int64() ||
    length > max_body_bytes.to_int64() - self.received_content_length {
    return Err(Http3LimitExceeded("HTTP/3 message body", max_body_bytes))
  }
  if self.expected_content_length is Some(expected) &&
    !self.body_forbidden &&
    (
      self.received_content_length > expected ||
      length > expected - self.received_content_length
    ) {
    return Err(
      Http3StreamError(self.id, H3MessageError, "DATA exceeds Content-Length"),
    )
  }
  self.received_content_length += length
  Ok(())
}

///|
pub fn Http3Connection::receive_request_frame(
  self : Http3Connection,
  stream_id : Int64,
  frame : Http3Frame,
) -> Result[Array[H3Action], Http3Error] {
  if !self.settings_received {
    return Err(
      Http3ConnectionError(
        H3MissingSettings,
        "request stream data arrived before SETTINGS",
      ),
    )
  }
  let stream = match self.streams.get(stream_id) {
    Some(result) => result
    None =>
      return Err(
        Http3StreamError(
          stream_id,
          H3RequestIncomplete,
          "unknown request stream",
        ),
      )
  }
  let actions : Array[H3Action] = []
  match frame {
    H3Headers(section) => {
      let decoded = match
        self.decoder.decode_field_section(stream_id, section) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      match decoded {
        QpackBlocked(_) => ()
        QpackDecoded(fields, acknowledgment_required) => {
          let (trailers, informational) = match stream.receive_headers(fields) {
            Ok(result) => result
            Err(error) => return Err(error)
          }
          actions.push(
            H3HeadersReceived(stream_id, fields, trailers, informational),
          )
          if acknowledgment_required {
            let instruction = match qpack_section_acknowledgment(stream_id) {
              Ok(result) => result
              Err(error) => return Err(error)
            }
            actions.push(H3SendQpackDecoderInstruction(instruction))
          }
        }
      }
    }
    H3Data(data) =>
      match stream.receive_data(data, self.limits.max_body_bytes) {
        Ok(_) => actions.push(H3DataReceived(stream_id, data))
        Err(error) => return Err(error)
      }
    H3PushPromise(push_id, section) => {
      if self.role != H3Client {
        return Err(
          Http3ConnectionError(H3FrameUnexpected, "client sent PUSH_PROMISE"),
        )
      }
      let decoded = match
        self.decoder.decode_field_section(stream_id, section) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      match decoded {
        QpackBlocked(_) => ()
        QpackDecoded(fields, acknowledgment_required) => {
          match
            validate_http3_field_section(stream_id, fields, H3PushPromiseFields) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
          actions.push(H3PushPromiseReceived(stream_id, push_id, fields))
          if acknowledgment_required {
            let instruction = match qpack_section_acknowledgment(stream_id) {
              Ok(result) => result
              Err(error) => return Err(error)
            }
            actions.push(H3SendQpackDecoderInstruction(instruction))
          }
        }
      }
    }
    H3Unknown(typ, _) => actions.push(H3UnknownFrameIgnored(typ))
    _ =>
      return Err(
        Http3StreamError(
          stream_id,
          H3FrameUnexpected,
          "frame type is not permitted on an HTTP/3 request stream",
        ),
      )
  }
  Ok(actions)
}

///|
pub fn Http3Connection::finish_request_stream(
  self : Http3Connection,
  stream_id : Int64,
) -> Result[Unit, Http3Error] {
  let stream = match self.streams.get(stream_id) {
    Some(result) => result
    None =>
      return Err(
        Http3StreamError(
          stream_id,
          H3RequestIncomplete,
          "unknown request stream",
        ),
      )
  }
  if stream.phase == H3WaitingHeaders {
    return Err(
      Http3StreamError(
        stream_id,
        H3RequestIncomplete,
        "request stream ended before final headers",
      ),
    )
  }
  if stream.phase == H3MessageCancelled {
    return Ok(())
  }
  if stream.expected_content_length is Some(expected) &&
    !stream.body_forbidden &&
    stream.received_content_length != expected {
    return Err(
      Http3StreamError(
        stream_id,
        H3MessageError,
        "message body does not match Content-Length",
      ),
    )
  }
  stream.phase = H3MessageComplete
  self.streams.remove(stream_id)
  Ok(())
}

///|
pub fn Http3Connection::cancel_request_stream(
  self : Http3Connection,
  stream_id : Int64,
) -> Result[Bytes, Http3Error] {
  match self.streams.get(stream_id) {
    Some(stream) => stream.phase = H3MessageCancelled
    None => ()
  }
  self.decoder.cancel_stream(stream_id)
  self.streams.remove(stream_id)
  qpack_stream_cancellation(stream_id)
}

///|
pub fn Http3Connection::stream_phase(
  self : Http3Connection,
  stream_id : Int64,
) -> H3MessagePhase? {
  match self.streams.get(stream_id) {
    Some(stream) => Some(stream.phase)
    None => None
  }
}

///|
pub fn Http3Connection::feed_qpack_encoder_stream(
  self : Http3Connection,
  bytes : BytesView,
) -> Result[Array[Int64], Http3Error] {
  match self.decoder.feed_encoder_stream(bytes) {
    Ok(_) => Ok(self.decoder.ready_blocked_streams())
    Err(error) => Err(error)
  }
}

///|
pub fn Http3Connection::feed_qpack_decoder_stream(
  self : Http3Connection,
  bytes : BytesView,
) -> Result[Unit, Http3Error] {
  self.encoder.feed_decoder_stream(bytes)
}

///|
pub fn Http3Connection::encode_headers_frame(
  self : Http3Connection,
  stream_id : Int64,
  fields : Array[QpackField],
) -> Result[Bytes, Http3Error] {
  let section = match self.encoder.encode_field_section(stream_id, fields) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  encode_http3_frame(H3Headers(section))
}

///|
pub fn Http3Connection::encode_data_frame(
  self : Http3Connection,
  data : Bytes,
) -> Result[Bytes, Http3Error] {
  if data.length() > self.limits.max_body_bytes {
    return Err(Http3LimitExceeded("HTTP/3 DATA", self.limits.max_body_bytes))
  }
  encode_http3_frame(H3Data(data))
}
