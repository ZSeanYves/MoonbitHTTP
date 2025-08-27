pub suberror IoError {
  Eof         // 数据读尽且已关闭
  Closed      // 本端已关闭，不能再 I/O
//Timeout     // 预留：读/写超时
  WouldBlock  // 当前暂无可读/可写数据（非阻塞场景）
//Other(String)
}

pub suberror BufError {
  NeedMore(String) // 数据不够，暂时无法完成本次读取（例如还没遇到 CRLF）
  LineTooLong(String) // 行长度超过允许上限
}


// 小工具：是否为“致命错误”（WouldBlock 通常不是致命）
pub fn io_is_fatal(e : IoError) -> Bool {
  match e {
    IoError::WouldBlock => false
    _ => true
  }
}