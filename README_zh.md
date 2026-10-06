# ZSeanYves/MoonbitHTTP

MoonbitHTTP 是 MoonBit 的流式 HTTP 基础库。`0.7.0` 是面向 v1 架构的
破坏性 alpha 开发线。

## 功能（Features）

- **[portable] HTTP/1.1**：增量请求/响应 codec、消息 framing、trailer、输入
  校验，以及异步服务和客户端接入。
- **[portable] HTTP/2**：frame、HPACK、SETTINGS、GOAWAY/RST、多路复用流、
  有界流控、h2c 升级和异步服务驱动。
- **[portable] HTTP/3 与 QUIC 引擎**：QPACK、关键流、请求流状态、packet
  protection、恢复、路径验证和传输状态。当前提供的是协议引擎与 driver
  API，尚未提供通用的 HTTP/3 应用服务层。
- **[portable] 统一 HTTP 数据类型**：经过校验的 `Request`、`Response`、`HeaderMap`、
  URI/authority、endpoint、资源限制和类型化错误。
- **[portable] 流式 Body**：有界队列、背压、取消、trailer，以及请求/响应 Body 的
  显式生命周期管理。
- **[portable] 可选策略**：认证、Cookie、缓存决策、重定向、重试和有界的内容编码
  转换。
- **[host] 显式能力注入**：由宿主提供 stream/datagram I/O、名称解析、时钟、熵源、
  TLS 和 `NetworkPolicy`。协议代码不会创建 socket，也不会偷偷执行 DNS。
- **[native] Native 适配器**：TCP/UDP、resolver、clock、基于 OpenSSL 的普通 TLS
  与 QUIC TLS，以及 Native client/server 接线。
- **[host] 回调接入**：`adapter/uv` 把宿主回调桥接为 async `Reader`/`Writer`，
  但不选择具体 socket 或 TLS 后端。
- **[driver-level] HTTP/3/QUIC smoke 与互操作**：Native loopback 和独立
  driver 检查覆盖协议边界；这不等于通用 HTTP/3 应用服务。

## 目标支持

| 能力 | Native | Wasm / Wasm-GC | JavaScript |
| --- | --- | --- | --- |
| `core/*`、`protocol/*`、`runtime/*`、`application/*`、`policy/*` | 可编译，并可在注入能力后运行 | 可编译，并可在宿主能力下运行 | 可编译，并可在宿主能力下运行 |
| HTTP/1 和 HTTP/2 service 接口 | 可用，网络由 adapter 提供 | 可用，需宿主注入网络能力 | 可用，需宿主注入网络能力 |
| Native TCP/UDP/DNS/OpenSSL | 支持 | 不支持 | 不支持 |
| HTTP/3/QUIC 协议状态 | 可编译；提供 Native driver/TLS fixture | 可编译；datagram 和 QUIC TLS 由宿主提供 | 可编译；datagram 和 QUIC TLS 由宿主提供 |
| HTTP/3 网络 TLS | Native OpenSSL；QUIC TLS 需要 OpenSSL 3.5+ | 宿主提供 | 宿主提供 |
| 浏览器 fetch/WebSocket | 不适用 | 不承诺 | 不承诺 |

“可移植编译”表示包可以为目标构建，并不表示目标自动拥有网络能力。Wasm
和 JS 构建不能导入 `adapter/native/*`；库不会假设浏览器 API、DNS、UDP 或
TLS 已经存在。

## 包分层

- **`core/*`**：协议无关的类型、有界 codec 基础设施和流式 Body 契约。
- **`protocol/*`**：HTTP/1.1、HTTP/2、HTTP/3、QUIC 和可移植 TLS 状态。
- **`runtime/*`**：能力契约、协议检测和 HTTP/1/H2 服务生命周期，包括 h2c。
- **`application/*`**：客户端策略/连接池和服务端 dispatch 契约。当前具体
  的 Native 便捷客户端面向 HTTP/1.1。
- **`policy/*`**：可选的认证、缓存、Cookie 和内容编码策略。
- **`adapter/native/*`**：Native socket、resolver、clock 和 OpenSSL provider。
- **`adapter/uv`**：回调到 async I/O 的宿主桥接层。

包职责和依赖边界见[包地图](docs/concepts/packages.md)与[架构说明](docs/concepts/architecture.md)。

## 范围与限制

当前 HTTP/1.1 和 HTTP/2 的应用覆盖最完整。HTTP/3 与 QUIC 层提供可移植
codec、状态机和 driver action；当前 service 层不会把它们隐式变成完整的
HTTP/3 client 或 server。Native QUIC TLS 使用 OpenSSL provider，并需要
OpenSSL 3.5 或更高版本。

Native TLS 支持显式 trust anchor、证书身份校验、mTLS、离线 CRL 检查和
stapled OCSP 校验。在线 OCSP 获取以及 Wasm 的 Native 风格撤销 provider
不在本次发布范围内。

异步运行时采用协作式调度。应用 handler 和宿主能力实现需要主动 yield，
并保证受保护清理有界，取消和关闭才能完成。

本项目是经过充分验证的开发基础库，不宣称已经达到生产就绪或标准库兼容
水平。当前的本地/loopback 互操作、受控 Native 性能运行和定向安全回归只
说明各自声明的环境，不能推出公网、跨平台、长时间运行或完整独立安全审计
结论。当前修复索引中的已知问题已有针对性修复和回归验证；历史深度扫描的
覆盖仍不完整。
当前独立候选复核仍有三个路径待处置，因此不能把这些定向回归当作完整安全
扫描或生产批准。

## 验证与后续入口

- [快速开始](docs/guide/getting-started.md)：使用显式能力构造客户端。
- [架构说明](docs/concepts/architecture.md)：依赖和状态机边界。
- [验证事实](docs/release/current.md)：当前证据与剩余发布工作。
- [发布门槛](docs/release/gates.md)：生产发布条件。
- [性能方法](docs/development/performance.md)：受控 Native 回归与独立 Go
  `net/http` H1/H2 参考工具。
- [变更记录](CHANGELOG.md)：版本级行为和 API 变化。

规范包路径见[包地图](docs/concepts/packages.md)。在 `0.7.0` alpha 阶段，
移动包会改变 import identity，属于破坏性变更。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
