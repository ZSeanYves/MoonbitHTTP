# 面向 MoonBit 的流式 HTTP 协议套件

MoonbitHTTP 为 MoonBit 提供可移植的 HTTP/1.1、HTTP/2、HTTP/3、QUIC、TLS、
流式 Body 和策略组件。`0.7.0` 是破坏性的 alpha 架构线，`1.0.0` 之前公共
API 可能变化。

协议包是与能力无关的状态机。网络访问、解析、时钟、熵源、TLS 和授权由
宿主显式提供，使可移植包可以在 Native、Wasm、Wasm-GC 和 JavaScript 上编译，
同时清楚区分各目标实际拥有的网络能力。

## 安装

`0.7.0` 发布到 Mooncakes 后，可在 MoonBit 项目根目录运行：

```bash
moon add ZSeanYves/MoonbitHTTP@0.7.0
```

当前源码请直接 clone 仓库并使用项目锁定的 MoonBit 工具链；发布前的源码验证
以仓库 CI 和 release 检查为准。

包地图和依赖边界见
[`docs/concepts/packages.md`](docs/concepts/packages.md)。各包的 API 说明
放在包目录旁，生成的 `.mbti` 文件仍是规范接口表面。

## 包

- `core/types`、`core/body`、`core/codec`：HTTP 值、流式 Body、取消、背压和
  有界字节 codec。
- `protocol/http1`、`protocol/http2`、`protocol/http3`、`protocol/quic`、
  `protocol/tls`：增量 framing 和协议状态机；这些包不会打开 socket。
- `runtime/transport`、`runtime/service`、`runtime/detection`：宿主能力契约、
  协议探测、HTTP/1 与 HTTP/2 服务生命周期以及 h2c。
- `application/client`、`application/server`：请求编排、连接池和服务端分发契约。
- `policy/auth`、`policy/cache`、`policy/cookie`、`policy/content_coding`：
  可选 HTTP 策略。
- `adapter/native/*`：Native TCP/UDP、resolver、clock、OpenSSL 普通 TLS 和
  QUIC TLS 适配器。
- `adapter/uv`：把宿主 callback 接入 async `Reader`/`Writer`。

## 功能

- [x] **[portable] HTTP/1.1**：增量消息、framing、trailer、校验以及服务/客户端接入。
- [x] **[portable] HTTP/2**：frame、HPACK、SETTINGS、GOAWAY/RST、多路复用、
  流控、h2c 和具备生命周期管理的服务。
- [x] **[portable] HTTP/3 与 QUIC 引擎**：QPACK、关键流、请求流状态、packet
  protection、恢复、CID 和路径状态。
- [x] **[portable] 统一 HTTP 值**：`Request`、`Response`、`HeaderMap`、URI、
  authority、endpoint、限制和类型化错误。
- [x] **[portable] 流式 Body**：有界队列、背压、取消、trailer 和显式 Body 所有权。
- [x] **[portable] 可选策略**：认证、Cookie、缓存决策、重定向、重试和有界内容编码。
- [x] **[host] 能力注入**：stream/datagram I/O、resolver、clock、entropy、TLS 和
  `NetworkPolicy` 都是显式输入。
- [x] **[host] Callback 接入**：`adapter/uv` 把宿主 callback 转为 async `Reader`/`Writer`。
- [x] **[native] TCP/UDP、DNS 与 Native client/server 适配器**：提供宿主 socket
  和 resolver 接线；HTTP 语义与 HTTP/1.1 framing 分别对照
  [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110) 和
  [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112)。
- [x] **[native] OpenSSL 普通 TLS**：在适配器边界执行证书身份和信任校验；TLS 1.3
  对照 [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446)，主机名身份规则对照
  [RFC 6125](https://www.rfc-editor.org/rfc/rfc6125)。
- [x] **[native] QUIC TLS provider**：OpenSSL 3.5+ 提供 Native QUIC TLS callback；
  协议边界对照 [RFC 9001](https://www.rfc-editor.org/rfc/rfc9001) 与
  [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446)。
- [x] **[native] HTTP/3/QUIC smoke 与互操作 driver**：Native loopback 和独立
  driver 检查覆盖 [QUIC v1 RFC 9000](https://www.rfc-editor.org/rfc/rfc9000)、
  [HTTP/3 RFC 9114](https://www.rfc-editor.org/rfc/rfc9114) 与
  [QPACK RFC 9204](https://www.rfc-editor.org/rfc/rfc9204)。

RFC 链接说明实现对照的协议契约，不表示所有可选扩展或部署配置都已实现。

## 目标支持

| 能力 | Native | Wasm / Wasm-GC | JavaScript |
| --- | --- | --- | --- |
| core、codec、protocol、policy | 可编译和使用 | 可编译和使用 | 可编译和使用 |
| HTTP/1.1 与 HTTP/2 service 接口 | 通过 adapter 可用 | 可用，需宿主能力 | 可用，需宿主能力 |
| Native TCP/UDP/DNS/OpenSSL 适配器 | 支持 | 不支持 | 不支持 |
| HTTP/3/QUIC 协议状态 | 可编译使用，提供 Native driver fixture | 可编译使用，需宿主 datagram/TLS | 可编译使用，需宿主 datagram/TLS |
| HTTP/3 网络 TLS | OpenSSL 3.5+ QUIC TLS provider | 宿主提供 | 宿主提供 |
| 浏览器 `fetch`/WebSocket 接入 | 不适用 | 不承诺 | 不承诺 |

“可编译使用”不等于自动获得网络访问。Wasm 和 JavaScript 必须提供所需宿主
能力，也不能导入 `adapter/native/*`。

## 示例

- [`examples/cmd/smoke_server`](examples/cmd/smoke_server/README.md)：有界的
  Native HTTP/1.1 和 h2c 服务 smoke fixture。
- [`examples/cmd/h3_smoke_server`](examples/cmd/h3_smoke_server/README.md)：有界的
  Native HTTP/3 与 QUIC loopback 互操作 fixture。

请按示例包 README 中的仓库 runner 运行；这些 fixture 用于验证，不是部署模板。

## 标准与范围

HTTP/1.1 和 HTTP/2 具有最完整的应用覆盖。HTTP/2 framing 与 HPACK 对照
[RFC 9113](https://www.rfc-editor.org/rfc/rfc9113) 和
[RFC 7541](https://www.rfc-editor.org/rfc/rfc7541)。HTTP/3 与 QUIC 当前提供
协议引擎和 driver action；本版本不承诺通用 HTTP/3 client/server service。

Native TLS 与 QUIC 必须显式选择 provider。Wasm 和 JavaScript 不会自动获得浏览器
网络、DNS、UDP 或 TLS。async runtime 使用协作式调度，宿主能力和应用 handler
需要主动 yield，并让取消清理保持有界。

## 验证状态

仓库在 CI 中执行 Native、Wasm、Wasm-GC 和 JavaScript 严格检查与测试、架构检查、
Native TLS 套件、HTTP/3/QUIC 互操作，以及受控 Native 性能/参考运行。这些是有界的
开发和 loopback 验证，不单独证明公网容量、长时间可靠性、跨平台部署覆盖或完整的
独立安全审计。

见 [`docs/release/current.md`](docs/release/current.md) 的证据摘要、
[`docs/release/gates.md`](docs/release/gates.md) 的发布条件，以及
[`CHANGELOG.md`](CHANGELOG.md) 的版本记录。

## 注意事项

- `0.7.0` 是 alpha 架构线，包路径可能发生破坏性变化。
- Native QUIC TLS 需要 OpenSSL 3.5 或更高版本。
- HTTP/3 service 编排、浏览器 fetch/WebSocket adapter 和在线 OCSP 获取不在当前范围。
- 可移植目标构建通过只证明包可编译，不证明该目标已经提供可用网络实现。

## 许可证

Apache License 2.0，见 [`LICENSE`](LICENSE)。
