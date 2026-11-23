# `examples/cmd/h3_smoke_client`

原生客户端连接 127.0.0.1:18444 上的 aioquic HTTP/3 服务端，验证同连接并发 POST 和 GET 的响应字节、证书身份及作用域关闭。请在仓库根目录先运行 `moon run repo-tools/tools/prepare_http3_interop.mbtx`，再运行 `moon run repo-tools/tools/http3_interoperability.mbtx --reverse`。
