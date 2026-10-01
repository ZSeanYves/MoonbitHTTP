///|
pub(all) struct QpackField {
  name : String
  value : Bytes
  sensitive : Bool
} derive(Eq)

///|
pub impl @debug.Debug for QpackField with fn to_repr(self) {
  @debug.Repr::record({
    "name": @debug.Repr::string(self.name),
    "value": if self.sensitive {
      @debug.Repr::literal("<redacted>")
    } else {
      @debug.Repr::opaque_(
        "Bytes",
        @debug.Repr::array(
          self.value
          .to_array()
          .map(byte => @debug.Repr::integer(byte.to_int().to_string())),
        ),
      )
    },
    "sensitive": @debug.Repr::bool(self.sensitive),
  })
}

///|
fn qpack_sensitive_name(name : String) -> Bool {
  name == "authorization" ||
  name == "proxy-authorization" ||
  name == "cookie" ||
  name == "set-cookie"
}

///|
fn qpack_valid_pseudo_name(name : String) -> Bool {
  if name.length() < 2 || name[0] != ':' {
    return false
  }
  for index in 1..<name.length() {
    let byte = name[index]
    if !((byte >= 'a' && byte <= 'z') ||
      (byte >= '0' && byte <= '9') ||
      byte == '-' ||
      byte == '_' ||
      byte == '.') {
      return false
    }
  }
  true
}

///|
fn qpack_validate_field(field : QpackField) -> Result[Unit, Http3Error] {
  if field.name.has_prefix(":") {
    if !qpack_valid_pseudo_name(field.name) {
      return Err(
        Http3ConnectionError(H3MessageError, "invalid HTTP/3 pseudo-field name"),
      )
    }
  } else {
    match @types.HeaderName::parse(field.name) {
      Ok(parsed) if parsed.value == field.name => ()
      _ =>
        return Err(
          Http3ConnectionError(
            H3MessageError,
            "invalid or uppercase HTTP/3 field name",
          ),
        )
    }
  }
  match @types.HeaderValue::from_bytes(field.value) {
    Ok(_) => Ok(())
    Err(_) =>
      Err(Http3ConnectionError(H3MessageError, "invalid HTTP/3 field value"))
  }
}

///|
pub fn QpackField::new(
  name : String,
  value : Bytes,
  sensitive? : Bool = false,
) -> Result[QpackField, Http3Error] {
  let field = {
    name,
    value,
    sensitive: sensitive || qpack_sensitive_name(name),
  }
  match qpack_validate_field(field) {
    Ok(_) => Ok(field)
    Err(error) => Err(error)
  }
}

///|
pub fn QpackField::from_strings(
  name : String,
  value : String,
  sensitive? : Bool = false,
) -> Result[QpackField, Http3Error] {
  QpackField::new(name, @utf8.encode(value), sensitive~)
}

// RFC 9204 Appendix A. QPACK indices are zero-based.
