# 回调传输适配器

导入 `ZSeanYves/MoonbitHTTP/adapter/callback`，即可将宿主的读、写和关闭回调接入 MoonBit 的异步字节流接口。

调用 `@callback.CallbackTransport::new`，传入异步读写回调和可选的关闭回调。读写回调接收缓冲区、偏移量和长度，返回实际传输的字节数。读取返回零表示 EOF，写入必须取得进展。计数无效时，I/O 错误携带的原因是 `CallbackCountError::InvalidReadCount` 或 `CallbackCountError::InvalidWriteCount`。
