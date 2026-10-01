# ZSeanYves/MoonbitHTTP

MoonbitHTTP 是 MoonBit 的流式 HTTP 协议库。`0.7.0` 是面向 v1 架构的
alpha 开发线，允许破坏 0.6 API，尚不是生产发布声明。

请先阅读[文档总入口](docs/README.md)：

- [快速开始](docs/guide/getting-started.md)
- [包地图与稳定性](docs/concepts/packages.md)
- [架构与依赖方向](docs/concepts/architecture.md)
- [当前验证证据](docs/release/current.md)
- [生产发布门槛](docs/release/gates.md)

当前包路径仍按职责保持独立：`types/body/codec` 是数据核心，
`http1/http2/http3/quic/tls` 是协议引擎，`transport/service` 是运行时契约和
连接驱动，`client/server` 是应用入口，`auth/cache/cookie/content_coding` 是
可选策略，`*/native` 和 `uv_adapter` 是宿主适配器。`test_support`、`cmd`、
`tools` 与 `scripts` 仅用于开发和验证。

Native 客户端必须显式接收 resolver、NetworkPolicy、clock 和 TLS provider；
Native TLS 需要 OpenSSL 3，QUIC TLS 需要 OpenSSL 3.5 或更新版本。协议核心
支持 Native、Wasm、Wasm-GC 和 JS；Native TLS/QUIC 的平台证据单独记录在发布
文档中。

当前验证数字、互操作工件、包摘要和未关闭门槛不放在 README 中，统一以
[发布证据](docs/release/current.md)为准。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
