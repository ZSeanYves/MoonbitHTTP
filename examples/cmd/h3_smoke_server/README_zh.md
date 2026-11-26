# `examples/cmd/h3_smoke_server`

[English](README.md) · [项目说明](../../../README_zh.md)

Native HTTP/3 示例服务，同时供互操作测试使用。服务监听 UDP `127.0.0.1:18443`，GET 返回文本，POST 回显请求正文并要求对端轮换目标连接 ID。示例从仓库读取本地测试证书和私钥。请在仓库根目录运行，使用 OpenSSL 3.5 或更高的 3.x 版本。

```sh
moon run examples/cmd/h3_smoke_server --target native

# 在另一终端运行
moon run examples/cmd/streaming_client --target native -- h3 get https://localhost:18443/ tests/fixtures/tls/localhost.cert.pem
```

在 `--target native` 后加上 `-- --once`，服务将在第一个请求处理函数启动时开始排空，等待此次交换结束后退出。

Native 容量探针支持安装 Go 的 macOS 和 Linux。在同一回环监听器上保持 0、100 或 1,000 条空闲 QUIC 连接，另建一条用于测量。每档先静置五秒，再以每 20 ms 一次 GET 的负载测量五秒。静置窗口包括边界处的两次快照。最后单独测量连续丢弃 35 ms 服务端数据报后一次 GET 的完成时延。请在仓库根目录运行，并将文件描述符软限制设为大于 1,001。

```sh
moon run repo-tools/tools/http3_idle_capacity.mbtx -- --baseline
moon run repo-tools/tools/http3_idle_capacity.mbtx
```

每次运行在 `_build/evidence/performance/h3-idle` 下保存服务端与探针的摘要、轮询次数、进程 CPU、RSS、操作系统提供的唤醒计数、各次请求延迟及恢复时间。基线命令检出 `3765516`，在原有 25 ms 循环增加计数，再编译同一个示例服务。

在应用中复用此监听方式时，将 `NativeHttp3Listener` 绑定到自己的端点和请求处理函数。[Native 服务端指南](../../../adapter/native/server/README_zh.md)
