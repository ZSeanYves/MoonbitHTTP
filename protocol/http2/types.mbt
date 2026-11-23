// Frame type constants use their wire-format integer values.

///|
pub const H2_FRAME_DATA : Int32 = 0x0

///|
pub const H2_FRAME_HEADERS : Int32 = 0x1

///|
pub const H2_FRAME_PRIORITY : Int32 = 0x2

///|
pub const H2_FRAME_RST_STREAM : Int32 = 0x3

///|
pub const H2_FRAME_SETTINGS : Int32 = 0x4

///|
pub const H2_FRAME_PUSH_PROMISE : Int32 = 0x5

///|
pub const H2_FRAME_PING : Int32 = 0x6

///|
pub const H2_FRAME_GOAWAY : Int32 = 0x7

///|
pub const H2_FRAME_WINDOW_UPDATE : Int32 = 0x8

///|
pub const H2_FRAME_CONTINUATION : Int32 = 0x9

// Frame flags are combined as bit masks.

///|
pub const H2_FLAGS_ACK : Int32 = 0x1 // SETTINGS, PING

///|
pub const H2_FLAGS_END_STREAM : Int32 = 0x1 // DATA and HEADERS

///|
pub const H2_FLAGS_END_HEADERS : Int32 = 0x4 // HEADERS/CONTINUATION

///|
pub const H2_FLAGS_PADDED : Int32 = 0x8 // DATA/HEADERS

///|
pub const H2_FLAGS_PRIORITY : Int32 = 0x20 // HEADERS

// RFC 7540 initial maximum frame size.

///|
pub const H2_DEFAULT_MAX_FRAME_SIZE : Int32 = 16384

// 24-byte client connection preface.

///|
pub const H2_CLIENT_PREFACE : String = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

// Fixed 9-byte frame header.

///|
pub(all) struct H2FrameHeader {
  length : Int32 // 24-bit (0..2^24-1)
  typ : Int32 // 8-bit
  flags : Int32 // 8-bit mask
  stream_id : Int32 // 31-bit (R bit = 0)
}

// A decoded frame retains its raw payload for higher-level interpretation.

///|
pub(all) struct H2Frame {
  header : H2FrameHeader
  payload : Array[Byte]
}

// SETTINGS payload entry: 16-bit identifier plus 32-bit value.

///|
pub(all) struct H2Setting {
  id : Int32
  value : Int32
}

///|
#derive(Debug, Eq)
pub(all) struct HpackHeader {
  name : String
  value : Bytes
}

///|
pub fn HpackHeader::from_strings(name : String, value : String) -> HpackHeader {
  { name, value: @utf8.encode(value), }
}

///|
pub fn HpackHeader::value_text(
  self : HpackHeader,
) -> Result[String, H2ProtocolError] {
  Ok(@utf8.decode(self.value)) catch {
    _ => Err(ConnectionError(ProtocolError, "header value is not valid UTF-8"))
  }
}
