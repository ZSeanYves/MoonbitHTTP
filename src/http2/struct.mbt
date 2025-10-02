// 常量：帧类型（用 Int 常量，避免枚举→Int 的转换麻烦）
pub const H2_FRAME_DATA          : Int = 0x0
pub const H2_FRAME_HEADERS       : Int = 0x1
pub const H2_FRAME_PRIORITY      : Int = 0x2
pub const H2_FRAME_RST_STREAM    : Int = 0x3
pub const H2_FRAME_SETTINGS      : Int = 0x4
pub const H2_FRAME_PUSH_PROMISE  : Int = 0x5
pub const H2_FRAME_PING          : Int = 0x6
pub const H2_FRAME_GOAWAY        : Int = 0x7
pub const H2_FRAME_WINDOW_UPDATE : Int = 0x8
pub const H2_FRAME_CONTINUATION  : Int = 0x9

// 标志位（按位组合）
pub const H2_FLAGS_ACK      : Int = 0x1     // SETTINGS, PING
pub const H2_FLAGS_END_STREAM : Int = 0x1   // DATA, HEADERS (同位值，按类型解释)
pub const H2_FLAGS_END_HEADERS: Int = 0x4   // HEADERS/CONTINUATION
pub const H2_FLAGS_PADDED     : Int = 0x8   // DATA/HEADERS
pub const H2_FLAGS_PRIORITY   : Int = 0x20  // HEADERS

// 默认最大帧长（RFC 7540：初始 16384）
pub const H2_DEFAULT_MAX_FRAME_SIZE : Int = 16384

// 客户端连接前言（24 字节）
pub const H2_CLIENT_PREFACE : String = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

// 结构：帧头（固定 9 字节）
pub(all) struct H2FrameHeader {
  length    : Int   // 24-bit (0..2^24-1)
  typ       : Int   // 8-bit
  flags     : Int   // 8-bit mask
  stream_id : Int   // 31-bit (R bit = 0)
}

// 读帧返回体（头 + 原始载荷）；更高层再按类型解析 payload
pub(all) struct H2Frame {
  header  : H2FrameHeader
  payload : Array[Byte]
}

// SETTINGS 帧（payload = N * (id(16) + value(32)))
pub(all) struct H2SettingKV {
  id : Int
  value : Int
}

// HEADERS / CONTINUATION 帧层（仅帧层，不做 HPACK）
// 头部信息（从 HEADERS 解出来的一些标志/优先级；都可选）
pub(all) struct H2HeadersInfo {
  stream_id   : Int
  end_stream  : Bool
  has_priority: Bool
  exclusive   : Bool
  dep_stream  : Int
  weight      : Int            // 1..256（协议里是 0..255 + 1，这里直接存原字节+1）
}

pub(all) struct H2Priority {
  exclusive : Bool
  dep_stream: Int
  weight    : Int  // 1..256
}


pub(all) struct HpackHeader {
  name  : String
  value : String
}

pub(all) struct HuffSym {
  code  : Int  // 右对齐（LSB 对齐）的“code as hex”
  bits  : Int  // code length in bits
}


pub struct HuffNode {
  left  : Int  // index of left child (-1 if none)
  right : Int  // index of right child (-1 if none)
  sym   : Int  // >=0 表示叶子符号（0..256），-1 表示非叶
}