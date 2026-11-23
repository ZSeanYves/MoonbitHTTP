# `examples/cmd/h3_smoke_client`

原生客户端用 Native resolver 解析 `localhost`，连接 127.0.0.1:18444 上的 aioquic HTTP/3 服务端，通过 `with_http3_pool` 验证同连接并发 POST 和 GET 的响应字节、跨源请求拒绝、证书身份及作用域关闭。请在仓库根目录先运行 `moon run repo-tools/tools/prepare_http3_interop.mbtx`，再运行 `moon run repo-tools/tools/http3_interoperability.mbtx --reverse`。

对端重启模式将连接池限制为一条连接。它检查两个未完成请求收到的传输错误，并验证同一个池能在参考服务端重启后完成下一次请求。运行方法见[互操作说明](../../../docs/development/interop.md#http3-peer-restart)。

长连接测试可指定 UDP 对端、HTTPS 名称、信任根、持续时间及并发数，所有 GET 和 POST 均在一条连接上校验完整响应。运行方法见[独立对端测试](../../../docs/development/interop.md#sustained-requests-to-a-separately-managed-http3-peer)。
