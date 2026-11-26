# `examples/cmd/h3_smoke_client`

[English](README.md) · [项目说明](../../../README_zh.md)

用于与固定版本 aioquic 服务互操作的 Native 客户端。运行器在 UDP 18444 端口启动对端，客户端核对并发 GET 和 POST 的响应内容，并检查跨源请求和证书主机名不匹配时的拒绝行为。请在仓库根目录运行，需要 Python 及 OpenSSL 3.5 或更高的 3.x 版本。

```sh
moon run repo-tools/tools/prepare_http3_interop.mbtx
moon run repo-tools/tools/http3_interoperability.mbtx --reverse
```

运行器还接受 `--peer-restart PATH_TO_QUIC_GO_SERVER`，检查对端重启后的恢复行为；针对独立部署的对端，可传入 `--peer-soak UDP_ADDRESS HTTPS_AUTHORITY CA_FILE SECONDS WORKERS`。

在 `--peer-soak` 模式下，各 worker 复用同一条已验证连接。追加 `--mixed` 可在该连接上交错运行大小两类请求。
