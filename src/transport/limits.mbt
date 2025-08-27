// I/O 与连接限制/超时配置（server/client/codec 可共享）
pub struct IoLimits {
  read_window_max : Int     // 每次最大读取窗口，限制缓冲膨胀
  write_buffer_max : Int    // 写端最大积压（回压控制占位）
  read_timeout_ms : Int     // 0 表示不限制
  write_timeout_ms : Int
}

pub fn default_limits() -> IoLimits {
  { read_window_max: 64 * 1024,
    write_buffer_max: 128 * 1024,
    read_timeout_ms: 0,
    write_timeout_ms: 0 }
}