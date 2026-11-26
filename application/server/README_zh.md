# `application/server`

[English](README.md) · [项目说明](../../README_zh.md)

用 `ServerSupervisor` 配合 `Listener` 接受连接、限制并发并协调关闭。监听器和请求处理函数由应用提供。`begin_shutdown` 停止接收新连接，并让已接收连接在配置的宽限期内结束。

调用 `last_accept_error()` 可查看最近一次接纳失败的原因。原生套接字的 `ListenerIo` 错误保留操作名和系统错误码。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/application/server",
}
```

将函数放入调用方包的 `.mbt` 文件中。

```moonbit
pub async fn[L : @server.Listener] serve(listener : L) -> Unit {
  let limits = { ..@server.ServerLimits::defaults(), max_connections: 128, }
  let config = @server.ServerConfig::defaults().with_limits(limits)
  let supervisor = @server.ServerSupervisor::new(config~).unwrap_or_error()
  supervisor.serve(listener).unwrap_or_error()
}
```
