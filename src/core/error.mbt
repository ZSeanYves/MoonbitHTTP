///|
pub suberror Herror {
  Io(String) // 读写失败、WouldBlock 等
  Proto(String) // 协议/解析错误（请求行非法、头越界、Host 缺失等）
  User(String) // 用户处理逻辑主动抛出的错误
}

// 便捷构造

///|
pub fn err_io(msg : String) -> Error {
  Herror::Io(msg)
}

///|
pub fn err_proto(msg : String) -> Error {
  Herror::Proto(msg)
}

///|
pub fn err_user(msg : String) -> Error {
  Herror::User(msg)
}

// 字符串化（日志/测试）

///|
pub fn error_to_string(e : Herror) -> String {
  match e {
    Herror::Io(s) => "Io: " + s
    Herror::Proto(s) => "Proto: " + s
    Herror::User(s) => "User: " + s
  }
}
