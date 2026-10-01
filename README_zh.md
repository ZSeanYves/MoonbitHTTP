# ZSeanYves/MoonbitHTTP

MoonbitHTTP 是 MoonBit 的流式 HTTP 协议库。`0.7.0` 是面向 v1 架构的
alpha 开发线，允许破坏 0.6 API，尚不是生产发布声明。

请先阅读[文档总入口](docs/README.md)：

- [快速开始](docs/guide/getting-started.md)
- [包地图与稳定性](docs/concepts/packages.md)
- [架构与依赖方向](docs/concepts/architecture.md)
- [当前验证证据](docs/release/current.md)
- [生产发布门槛](docs/release/gates.md)

包身份由 module 名称和包含 `moon.pkg` 的物理目录共同确定；移动目录会改变
import identity，因此属于破坏性变更。当前 0.7.0 alpha 的规范包路径如下：
`core/types`、`core/body`、`core/codec` 是数据核心，
`protocol/http1`, `protocol/http2`, `protocol/http3`, `protocol/quic`, `protocol/tls` 是协议引擎，`runtime/transport`, `runtime/service` 是运行时契约和
连接驱动，`application/client`, `application/server` 是应用入口，`policy/auth`, `policy/cache`, `policy/cookie`, `policy/content_coding` 是
可选策略，`adapter/native/*` 和 `adapter/uv` 是宿主适配器。`internal/test_support`、`examples/cmd`、
`repo-tools/tools` 与 `repo-tools/scripts` 仅用于开发和验证。

Native 客户端必须显式接收 resolver、NetworkPolicy、clock 和 TLS provider；
Native TLS 需要 OpenSSL 3，QUIC TLS 需要 OpenSSL 3.5 或更新版本。协议核心
支持 Native、Wasm、Wasm-GC 和 JS；Native TLS/QUIC 的平台证据单独记录在发布
文档中。

当前验证数字、互操作工件、包摘要和未关闭门槛不放在 README 中，统一以
[发布证据](docs/release/current.md)为准。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
