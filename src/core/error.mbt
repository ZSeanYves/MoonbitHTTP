///|
/// HTTP 库统一错误类型
pub suberror Herror {
  /// I/O 层错误（读写失败、连接关闭、超时等）
  Io(String)

  /// 协议 / 解析错误（请求行非法、头超限、状态码不合法等）
  Proto(String)

  /// 用户处理逻辑主动抛出的错误（例如 handler 主动失败）
  User(String)
}

///|
/// I/O 类错误构造
pub fn err_io(msg : String) -> Herror {
  Herror::Io(msg)
}

///|
/// 协议 / 解析类错误构造
pub fn err_proto(msg : String) -> Herror {
  Herror::Proto(msg)
}

///|
/// 用户逻辑错误构造
pub fn err_user(msg : String) -> Herror {
  Herror::User(msg)
}

///|
/// 文本化，方便日志 / 调试
pub fn error_to_string(e : Herror) -> String {
  match e {
    Herror::Io(s) => "Io: " + s
    Herror::Proto(s) => "Proto: " + s
    Herror::User(s) => "User: " + s
  }
}
