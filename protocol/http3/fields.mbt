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
fn h3_field_text(
  stream_id : Int64,
  field : QpackField,
) -> Result[String, Http3Error] {
  Ok(@utf8.decode(field.value)) catch {
    _ =>
      Err(
        Http3StreamError(
          stream_id,
          H3MessageError,
          "field value is not valid UTF-8",
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
/// Validates the HTTP semantics of a decoded field section. Extended CONNECT
/// is disabled unless the receiving server has advertised its support. Callers
/// validating outgoing requests pass the peer server's SETTINGS value; callers
/// validating incoming requests pass their own advertised value.
pub fn validate_http3_field_section(
  stream_id : Int64,
  fields : Array[QpackField],
  kind : H3FieldSectionKind,
  request_method? : String? = None,
  enable_connect_protocol? : Bool = false,
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
      let value = match h3_field_text(stream_id, field) {
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
        host = match h3_field_text(stream_id, field) {
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
      if parsed_authority.port is None {
        return Err(
          Http3StreamError(
            stream_id,
            H3MessageError,
            "CONNECT :authority must include a port",
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
      if protocol is Some(_) && !enable_connect_protocol {
        return Err(
          Http3StreamError(
            stream_id,
            H3MessageError,
            "extended CONNECT is not enabled by server SETTINGS",
          ),
        )
      }
      let path_value = match path {
        Some(value) => value
        None => ""
      }
      let parsed_path = match protocol {
        Some(_) => @types.Uri::parse_request_target(path_value, Get)
        None => @types.Uri::parse_request_target(path_value, http_method)
      }
      match parsed_path {
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
