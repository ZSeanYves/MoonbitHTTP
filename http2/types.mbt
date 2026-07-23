// Frame type constants use their wire-format integer values.

///|
pub const H2_FRAME_DATA : Int = 0x0

///|
pub const H2_FRAME_HEADERS : Int = 0x1

///|
pub const H2_FRAME_PRIORITY : Int = 0x2

///|
pub const H2_FRAME_RST_STREAM : Int = 0x3

///|
pub const H2_FRAME_SETTINGS : Int = 0x4

///|
pub const H2_FRAME_PUSH_PROMISE : Int = 0x5

///|
pub const H2_FRAME_PING : Int = 0x6

///|
pub const H2_FRAME_GOAWAY : Int = 0x7

///|
pub const H2_FRAME_WINDOW_UPDATE : Int = 0x8

///|
pub const H2_FRAME_CONTINUATION : Int = 0x9

// Frame flags are combined as bit masks.

///|
pub const H2_FLAGS_ACK : Int = 0x1 // SETTINGS, PING

///|
pub const H2_FLAGS_END_STREAM : Int = 0x1 // DATA and HEADERS

///|
pub const H2_FLAGS_END_HEADERS : Int = 0x4 // HEADERS/CONTINUATION

///|
pub const H2_FLAGS_PADDED : Int = 0x8 // DATA/HEADERS

///|
pub const H2_FLAGS_PRIORITY : Int = 0x20 // HEADERS

// RFC 7540 initial maximum frame size.

///|
pub const H2_DEFAULT_MAX_FRAME_SIZE : Int = 16384

// 24-byte client connection preface.

///|
pub const H2_CLIENT_PREFACE : String = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

// Fixed 9-byte frame header.

///|
pub(all) struct H2FrameHeader {
  length : Int // 24-bit (0..2^24-1)
  typ : Int // 8-bit
  flags : Int // 8-bit mask
  stream_id : Int // 31-bit (R bit = 0)
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
  id : Int
  value : Int
}

///|
pub(all) struct HpackHeader {
  name : String
  value : String
}

///|
priv struct HuffmanSymbol {
  code : Int // Right-aligned Huffman code.
  bits : Int // code length in bits
}

///|
priv struct HuffmanNode {
  left : Int // index of left child (-1 if none)
  right : Int // index of right child (-1 if none)
  sym : Int // 0..256 for a leaf symbol; -1 for an internal node.
}
