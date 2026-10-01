# ZSeanYves/MoonbitHTTP

MoonbitHTTP 是一个以流式处理为基础的 MoonBit HTTP 协议库。
当前版本为 `0.7.0` 开发版，允许破坏 0.6 API；生产验收仍以
[完整路线图](docs/production-http-roadmap.zh-CN.md) 为准。

[架构约定](docs/v1-architecture.md) · [实际依赖图](docs/v1-dependencies.md) ·
[验证分层与命令](docs/v1-testing.md) · [冻结基线](docs/v1-baseline-2026-09-29.md)

类型归属、构造参数和源码导航见 [0.6 → v1 迁移表](docs/v1-migration.md)。

## 职责划分

| 包 | 职责 |
| --- | --- |
| `types` | Request、Response、HeaderMap、Uri、Authority、IP、Endpoint 和 Limits |
| `body` | Body、背压、有界队列、取消和完成；不负责协议 framing |
| `codec` | 增量缓冲与 HPACK/QPACK 共用 Huffman 编解码 |
| `transport` | 连接、Datagram、resolver、policy、clock、entropy 和 TLS 能力契约 |
| `http1` / `http2` / `quic` / `http3` | 各协议的 codec、显式状态与 driver |
| `tls` | 纯 TLS 消息拆帧、QUIC 密钥派生与包保护 |
| `service` | HTTP/1、HTTP/2 连接驱动、作用域与关闭 |
| `client` / `server` | 请求策略、连接池、监听和生命周期调度 |
| `auth` / `cookie` / `cache` / `content_coding` | 可选应用策略，不反向依赖协议 driver |
| `*/native` | Native TCP、UDP、DNS、clock、OpenSSL TLS 和监听适配器 |
| `test_support` | 分片、故障、录制、固定时钟和内存 Datagram 测试工具 |

同一个协议包内部通过文件划分 codec、state 和 driver；不为每层再制造一组
转发 facade。依赖检查工具读取真实 `moon.pkg`，区分生产和测试依赖，并在 CI
拒绝违反分层的导入。

## 使用入口

通用 HTTP/1 客户端使用
`Http1Client::from_capabilities(connector, resolver, tls_provider, policy, clock)`。
Native 工厂为 `new_http1_client(resolver, policy, clock, tls_provider)`。
解析后的每个数字地址都必须再次经过策略授权。底层连接器不会自行 DNS；
callback executor 缺少 resolver 时只允许纯 IP endpoint。

策略客户端以显式大小限制聚合字节 Body；需要流式处理时使用 service driver
和 `BodyStream`。服务 handler 接收 `Request[BodyStream]`，返回
`Response[B]`（`B : Body`），驱动负责背压、取消及关闭。
HTTP/2 客户端通过 `with_h2_client_connection` 限定连接作用域，在 callback
返回之前消费所需响应 Body。

Native TLS 支持 CA 字节、客户端与服务端 PEM 凭据、证书校验和 ALPN。
普通 TLS 需要 OpenSSL 3，QUIC TLS 需要 **OpenSSL 3.5 或更新版本**。
安装与限制见 [Native TLS](tls/native/README.md)。当前 Native 验证平台为 macOS；
四目标编译适用于可移植协议核心。Windows Native TLS 和更多平台证据仍待补齐。

## 验证

Moon 命令共享构建锁，应串行执行：

```sh
moon fmt --check
moon run tools/check_architecture.mbtx
moon check --target all --deny-warn --warn-list +73
moon build --target all --deny-warn --warn-list +73
moon test --target all --deny-warn --warn-list +73
moon info --target all
moon run tools/interoperability.mbtx
moon run tools/benchmarks.mbtx
```

互操作工具强制使用 curl、wget、nghttp2，测试真实 TCP 上的 HTTP/1.1 GET/POST、
HTTP/2 prior knowledge 和 h2c。benchmark 工具实际执行 release 二进制并保留原始数据。
四目标测试、真实互操作、压力、性能门槛和安全审查是分别记录的证据。

`tools/release_evidence.mbtx` 拒绝脏工作树，逐项核对压缩包与冻结 Git 源码后才
保存发布证据。`moon package --list` 会重写压缩包，不是只读检查。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
