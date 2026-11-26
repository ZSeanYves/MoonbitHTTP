# `examples/cmd/smoke_server`

[English](README.md) · [项目说明](../../../README_zh.md)

在本机试用 HTTP/1.1 和 h2c 的 Native 示例服务。从仓库根目录启动，默认监听 `127.0.0.1:18080`。GET 返回一段文本，POST 原样返回请求正文。可在另一终端用流式客户端示例或 curl 访问。

```sh
moon run examples/cmd/smoke_server --target native

# 在另一终端运行
curl http://127.0.0.1:18080/
curl --data-binary 'hello' http://127.0.0.1:18080/echo
```

需要缓冲正文的互操作用例时，在 `--` 后传入 `--echo-h1 PORT` 或 `--echo-h2 PORT CERT KEY`。后者使用传入的 PEM 文件提供 HTTP/2 over TLS。两种模式收集的请求正文上限均为 1 MiB。

要用 MoonBit 发送流式 POST，可对 `/echo` 运行 `h1 upload` 示例。[流式客户端](../streaming_client/README_zh.md)
