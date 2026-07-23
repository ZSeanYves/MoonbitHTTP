///|
pub(all) enum Protocol {
  Http1
  Http2PriorKnowledge
  Http2Upgrade
} derive(Debug, Eq)

///|
pub(all) enum Detection {
  Undetermined
  Detected(Protocol)
} derive(Debug, Eq)

///|
pub struct Detector {
  prefix : Array[Byte]
  mut decision : Detection
}

///|
pub fn Detector::new() -> Detector {
  { prefix: [], decision: Undetermined }
}

///|
pub fn Detector::feed(self : Detector, bytes : BytesView) -> Detection {
  if self.decision is Detected(_) {
    for byte in bytes {
      self.prefix.push(byte)
    }
    return self.decision
  }
  let preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  for byte in bytes {
    self.prefix.push(byte)
    if self.decision is Detected(_) {
      continue
    }
    let index = self.prefix.length() - 1
    if index >= preface.length() || self.prefix[index] != preface[index] {
      self.decision = Detected(Http1)
    } else if self.prefix.length() == preface.length() {
      self.decision = Detected(Http2PriorKnowledge)
    }
  }
  self.decision
}

///|
pub fn Detector::buffered(self : Detector) -> Bytes {
  Bytes::from_array(self.prefix)
}

///|
fn has_token(headers : @types.HeaderMap, name : String, token : String) -> Bool {
  for value in headers.get_all_string(name) {
    for part in value.to_string_lossy().split(",") {
      if part.trim().to_lower() == token {
        return true
      }
    }
  }
  false
}

///|
pub fn detect_h2c_upgrade(headers : @types.HeaderMap) -> Bool {
  has_token(headers, "connection", "upgrade") &&
  has_token(headers, "connection", "http2-settings") &&
  has_token(headers, "upgrade", "h2c") &&
  headers.get_string("http2-settings") is Some(_)
}

///|
pub fn select_protocol(
  alpn : String?,
  cleartext_prefix : BytesView,
) -> Detection {
  match alpn {
    Some("h2") => Detected(Http2PriorKnowledge)
    Some("http/1.1") => Detected(Http1)
    Some(_) => Undetermined
    None => {
      let detector = Detector::new()
      detector.feed(cleartext_prefix)
    }
  }
}
