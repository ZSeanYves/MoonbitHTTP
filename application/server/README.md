# `application/server`

[中文](README_zh.md) · [Project README](../../README.md)

Use `ServerSupervisor` with a `Listener` to accept connections, enforce concurrency limits and coordinate shutdown. The application supplies the listener and request handler. `begin_shutdown` stops admission and starts draining existing connections under the configured grace period.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/application/server",
}
```

Add this function to a `.mbt` file in the importing package.

```moonbit
pub async fn[L : @server.Listener] serve(listener : L) -> Unit {
  let limits = { ..@server.ServerLimits::defaults(), max_connections: 128, }
  let config = @server.ServerConfig::defaults().with_limits(limits)
  let supervisor = @server.ServerSupervisor::new(config~).unwrap_or_error()
  supervisor.serve(listener).unwrap_or_error()
}
```
