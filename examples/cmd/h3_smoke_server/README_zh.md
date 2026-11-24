# `examples/cmd/h3_smoke_server`

[English](README.md) · [项目说明](../../../README_zh.md)

Native HTTP/3 示例服务，同时供互操作测试使用。服务监听 UDP `127.0.0.1:18443`，GET 返回文本，POST 回显请求正文并要求对端轮换目标连接 ID。示例从仓库读取本地测试证书和私钥。请在仓库根目录运行，使用 OpenSSL 3.5 或更高的 3.x 版本。

```sh
moon run examples/cmd/h3_smoke_server --target native

# 在另一终端运行
moon run examples/cmd/streaming_client --target native -- h3 get https://localhost:18443/ tests/fixtures/tls/localhost.cert.pem
```

在 `--target native` 后加上 `-- --once`，服务将在第一个请求处理函数启动时开始排空，等待此次交换结束后退出。
