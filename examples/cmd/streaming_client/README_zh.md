# `examples/cmd/streaming_client`

[English](README.md) · [项目说明](../../../README_zh.md)

演示 Native 上 HTTP/1.1、HTTP/2 和 HTTP/3 的流式请求。从仓库根目录运行以下命令，访问已启动的[本地示例服务](../smoke_server/README_zh.md)。输出包含响应状态码和正文长度。

```sh
moon run examples/cmd/streaming_client --target native -- h1 get http://127.0.0.1:18080/
moon run examples/cmd/streaming_client --target native -- h1 upload http://127.0.0.1:18080/echo
```

参数为 `h1|h2|h3 get|upload ABSOLUTE_URI [CA_PEM]`。所选协议应与目标服务匹配。访问使用私有 CA 的 HTTPS 源站时可传入信任锚文件。GET 的时限为 30 秒；上传持续产生数据块，直到一秒期限到达或响应提前结束。收集的响应正文上限为 1 MiB。
