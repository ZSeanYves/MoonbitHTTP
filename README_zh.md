# ZSeanYves/MoonbitHTTP

MoonbitHTTP 是 MoonBit 的流式 HTTP 基础库。`0.7.0` 是面向 v1 架构的
破坏性 alpha 开发线，尚不是生产发布声明。

## 功能范围

- HTTP/1.1、HTTP/2 的 framing、状态机和客户端/服务端驱动。
- HTTP/3、QUIC 的 packet、stream、连接状态，以及 TLS 1.3 接入边界；
  相关完整互操作仍受独立发布门槛约束。
- 统一的 `Request`、`Response`、`HeaderMap`、URI/authority、资源限制和
  分层错误（`core/types`）。
- 支持取消、背压和生命周期管理的流式 Body（`core/body`）。
- 可选的认证、Cookie、缓存和内容编码策略。
- 显式注入 resolver、stream/datagram、clock、entropy、TLS 和
  `NetworkPolicy`；协议层不创建 socket，也不偷偷执行 DNS。

整体分层对标 Go `net/http`、Hyper 等成熟库：协议 codec/state、传输能力
和应用策略相互分离，Request/Response 原生支持流式处理。当前 HTTP/1.1、
HTTP/2 覆盖最完整；HTTP/3/QUIC 的完整 TLS 凭据与负向套件、长时互操作、
性能阈值和最终安全审查仍是发布门槛。因此它是经过严格验证的开发基础库，
还不能宣称已经达到成熟标准库的生产交付水平。

## Native 与 Wasm

可移植包（`core/*`、`protocol/*`、`runtime/*`、`application/*`、
`policy/*`）可编译到 Native、Wasm、Wasm-GC 和 JS；这些包提供协议和策略
逻辑，本身不绑定操作系统网络。

Native 可使用 `adapter/native/*` 获得 TCP/UDP、resolver、clock 和基于
OpenSSL 的 TLS；QUIC TLS 需要 OpenSSL 3.5 或更高版本。这些适配器被隔离在
可移植依赖图之外。

Wasm 可以使用同一套协议和客户端 API，但必须由宿主注入 stream、datagram、
resolver 和 TLS 能力。MoonbitHTTP 不假设 Wasm 环境自带浏览器 socket、DNS、
UDP 或 TLS；Wasm 构建也不能导入 `adapter/native/*`。MoonX 等宿主可以提供
这些能力，最终可用的网络功能取决于宿主实现。

## 文档入口

- [快速开始](docs/guide/getting-started.md)
- [包地图](docs/concepts/packages.md)
- [架构与依赖边界](docs/concepts/architecture.md)
- [验证证据与发布门槛](docs/release/current.md)

规范包路径见[包地图](docs/concepts/packages.md)。在 `0.7.0` alpha 阶段，
移动包会改变 import identity，属于破坏性变更。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
