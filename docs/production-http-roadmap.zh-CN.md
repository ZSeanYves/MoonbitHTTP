# MoonbitHTTP 生产级 HTTP 协议库路线计划书

状态：设计基线，面向 `0.6.0` 之后的实现工作。

本文档定义 MoonbitHTTP 从“可互操作的 HTTP/1.1、HTTP/2 流式库”扩展为“可实际部署的纯 MoonBit HTTP 协议库”的架构、公共契约、实现顺序和发布门槛。它是实现约束，不是对当前版本已经具备的能力的重新声明。

## 1. 目标和边界

### 1.1 最终目标

MoonbitHTTP 应提供以下能力：

- HTTP 语义、URI、字段、消息 framing 和错误模型符合 RFC 9110；
- HTTP/1.0 兼容解析，HTTP/1.1 生产级客户端和服务端，覆盖持久连接、pipeline 安全处理、chunked、trailers、升级和严格长度校验；
- HTTP/2 客户端和服务端，覆盖 SETTINGS、HPACK、流状态、流量控制、GOAWAY、RST_STREAM、多路复用、h2c 和 ALPN 选择；
- HTTP/3 客户端和服务端，覆盖 QUIC v1、TLS 1.3 在 QUIC 上的握手、QPACK、HTTP/3 stream、取消、连接迁移策略和拥塞/丢包处理；
- 通用客户端层提供连接池、重定向、受策略控制的重试、Cookie、HTTP/HTTPS 代理、Basic/Digest/Bearer 认证、客户端证书、内容编码和可选缓存；
- 所有协议状态机可在 Native、Wasm、Wasm-GC 和 JS 编译。网络、文件、时钟、随机数和 TLS 后端通过能力接口注入；
- 不可信输入导致可传播的结构化错误或取消，不通过 `abort`、宿主命令或隐式全局状态逃逸。

### 1.2 明确不属于核心目标

本路线不把 FTP、SFTP/SSH、SMTP、WebSocket、Kerberos、NTLM、完整浏览器安全策略或操作系统网络配置纳入 HTTP 核心。它们可以作为独立模块消费本库的 URI、字段、Body 和传输接口。

HTTP/3 的 0-RTT 默认关闭，因为早期数据可被重放；只有调用方明确声明请求可重放并提供重放策略时才允许启用。SOCKS、HTTP/3 Datagram 和 CONNECT-UDP 在第一版生产发布中只保留扩展点，不作为默认承诺。

### 1.3 已有基线

当前仓库已经有以下可保留的基础：

```text
types -> body -> codec -> http1/http2 -> service
                                      ^
                         async/io Reader + Writer
```

`HeaderMap`、泛型 `Request[B]`/`Response[B]`、`Body` trait、`BodyStream`、有界队列、HTTP/1.1 framing、HTTP/2 HPACK 和连接级流控是现有实现的演进基线。现有同步或异步调用方应通过兼容层逐步迁移，不在一次变更中重写全部公共 API。

## 2. 架构方向

### 2.1 四个独立平面

库按四个平面组织。每个平面只能依赖自己下面的平面，不能由协议包直接调用宿主 API。

```text
应用策略平面：client / server / cookie / cache / auth / content_coding
协议平面：     http1 / http2 / http3 / hpack / qpack
传输平面：     transport / tls / quic / resolver / clock / entropy
数据平面：     types / body / codec / limits / error
```

- **数据平面**只处理拥有的数据、视图、长度和边界，不产生 I/O。
- **协议平面**是可暂停的增量状态机。它接收字节或帧，返回事件和待发送字节，不创建 socket，也不查文件系统。
- **传输平面**把能力接口接到 TCP、UDP、TLS、DNS、时钟和随机数。Native 可以使用宿主实现；Wasm 使用宿主注入或受控适配器。
- **应用策略平面**实现客户端和服务端的产品行为，例如重定向、重试、Cookie、认证和落盘。它不能绕过协议层的限制或错误。

推荐的包布局如下；包名是方向约束，具体文件可以按 MoonBit 的 `///|` block 习惯拆分：

```text
types/             公共请求、响应、字段、URI、版本、限制
body/              Body trait、流式 body、背压、取消和收尾
codec/             增量字节缓冲、整数、边界、通用 codec 错误
http1/             HTTP/1.x parser、framing、encoder、事件
http2/             frame、HPACK、stream/connection state、scheduler
http3/             H3 frame、request stream、QPACK adapter、settings
quic/              QUIC packet、ACK、丢包恢复、拥塞、stream 和 connection ID
tls/               TLS facade、证书策略、ALPN、SNI、客户端证书
transport/         stream/datagram/connector/resolver 的能力契约
service/           协议连接驱动、server handler、client connection scope
client/            URL 请求、连接池、重定向、重试、代理、认证、Cookie
server/            listener、路由无关的请求分发、优雅关闭和并发上限
cookie/            RFC 6265/6265bis 解析、存储、匹配和过期
cache/             RFC 9111 的可插拔缓存策略
auth/              Basic、Digest、Bearer、客户端证书的挑战状态机
content_coding/    gzip、deflate、Brotli 等 Body 编解码适配
```

`client` 和 `server` 可以依赖 `service`，但 `http1/http2/http3` 不能依赖它们。`tls` 不能把证书验证、随机数或 socket 写死在包内；`quic` 只依赖 `transport` 的 datagram/clock/entropy 和 TLS facade。各层的公共类型要由拥有该概念的包定义，避免从 `internal` 包重新导出具体类型。

### 2.2 协议核心与驱动分离

每个协议实现都应有相同的两类接口：

1. **无 I/O 的 codec/state machine**：给定 `BytesView` 或事件，返回 `NeedMoreInput`、`Produced`、`Complete` 或结构化错误；输出缓冲满时保留状态，不丢失已消费和未消费的边界。
2. **异步 driver**：使用 `Reader`/`Writer` 或 datagram 能力反复驱动状态机，施加读取、写入、body、并发和时间限制。

driver 不应把所有响应 body 聚合成 `Bytes`。只有调用方显式调用 `body.collect(max_bytes=...)` 时才聚合；默认通过 `BodyStream` 传递背压。

HTTP/2 和 HTTP/3 driver 必须拥有连接级 reader task、发送调度器和 stream registry。调用作用域结束时，所有 stream、reader task 和 writer 必须关闭或完成，禁止遗留 detached task。

### 2.3 宿主能力接口

协议库只依赖抽象能力。接口名称可以在实现阶段按 MoonBit trait 语法调整，但语义必须保持一致：

```text
StreamConnector
  connect(Endpoint, ConnectOptions) -> StreamConnection

DatagramSocket
  send(BytesView, Endpoint) -> Unit
  receive(max_bytes) -> Datagram

NameResolver
  resolve(Host, ResolveOptions) -> Array[IpAddress]

TlsProvider
  client_handshake(StreamConnection, TlsOptions) -> SecureConnection

Clock
  monotonic_millis() -> Int64
  wall_clock_seconds() -> Int64

Entropy
  fill(FixedArray[Byte]) -> Unit

NetworkPolicy
  authorize(Endpoint, Operation) -> Result[Unit, PolicyError]
```

能力接口的约定：

- `NetworkPolicy` 在 DNS、连接、重定向、代理 CONNECT、替代服务和 QUIC endpoint 变化前都要重新检查；
- `Clock` 的 deadline 使用单调时钟，HTTP Date 和 Cookie Expires 使用墙上时钟；
- `Entropy` 只负责提供随机字节，不在库内伪造随机数；
- `TlsProvider` 的成功结果必须包含协商版本、cipher suite、ALPN 和 peer identity，调用方不得根据日志猜测认证状态；
- 能力拒绝必须保留为 `PolicyError`，不能伪装成 DNS、TLS 或 HTTP 错误；
- 测试使用内存 stream、内存 datagram、固定时钟和确定性 entropy，不依赖真实网络。

初期继续保留现有宿主 TLS 适配器。纯 MoonBit TLS/PKI 实现只能通过同一 facade 接入，完成互操作、证书路径验证、负向测试和独立审查后，才允许替换默认 Native 后端。

## 3. 公共抽象和结构类型

### 3.1 请求、响应和字段

公共类型应保持以下语义，字段是否直接公开由兼容迁移决定；新类型优先使用构造函数和访问器，避免调用方破坏不变量。

```text
Method
  Get | Head | Post | Put | Delete | Options | Trace | Connect
  | Patch | Extension(String)

Version
  Http10 | Http11 | Http2 | Http3

HeaderName
  已验证的 token；统一小写比较，保留规范化后的显示值

HeaderValue
  原始 Bytes；只有明确要求文本时才转换 String

HeaderMap
  保留重复字段和字段顺序；提供 get、get_all、append、set、remove

Uri
  scheme、authority、path、query、fragment 的验证后表示

Request[B]
  method、target/uri、version、headers、body、extensions

Response[B]
  status、version、headers、body、extensions

Limits
  max_start_line、max_header_line、max_header_count、max_header_bytes、
  max_body_bytes、max_buffer_bytes、max_streams、max_concurrent_requests、
  max_dynamic_table_bytes、max_datagram_bytes
```

`HeaderMap` 必须允许重复字段，因为 `Set-Cookie` 等字段不能被逗号合并。字段名和字段值验证必须在构造入口完成；HTTP/1 禁止 obs-fold 和请求走私组合，HTTP/2/3 必须拒绝连接级字段和伪字段顺序错误。`Uri` 解析失败返回 `UriError`，不返回部分有效对象。

### 3.2 Body 和生命周期

现有 `Body` trait 继续作为核心抽象：

```text
Body
  next_frame() -> Frame?
  size_hint() -> SizeHint

Frame
  Data(Bytes)
  Trailers(HeaderMap)

SizeHint
  lower_bound、upper_bound?

BodyStream
  有界队列、finish、fail、cancel、消费回调
```

约定如下：

- Body 的所有权属于请求或响应，driver 不在后台继续读取已关闭的 body；
- `Data` 为空时不产生无限空事件；`Trailers` 后不得再产生 `Data` 或第二个 `Trailers`；
- `SizeHint` 只是 framing 提示，实际长度仍由协议层校验；
- `collect` 必须有显式字节上限，超过上限返回 `BodyLimitExceeded` 并取消上游；
- 未消费的响应 body 在 connection scope 结束时被取消并释放队列，不能阻塞连接关闭；
- body 生产者发生错误时，消费者得到原始错误的保留包装，而不是泛化成 EOF。

### 3.3 客户端和连接类型

客户端层建议提供以下稳定概念：

```text
Endpoint       scheme、host、port、代理目标
RequestOptions headers、body、deadline、redirect、retry、auth、cookie、limits
RedirectPolicy 禁止、有限次数、无限但有 loop detection
RetryPolicy    禁止、幂等方法、显式可重试方法；退避和 Retry-After
TlsOptions     verify_peer、server_name、alpn、trust_anchors、client_cert
ProxyConfig    direct、HTTP proxy、HTTPS CONNECT、认证信息
Client         连接池、CookieJar、缓存和策略状态的拥有者
Connection     一个协议连接的作用域和关闭状态
```

连接池的 key 至少包含 scheme、目标 authority、代理 endpoint、TLS identity 和协议选项。连接池不能跨 `Client` 共享 Cookie、认证凭据或缓存状态。连接复用前必须确认协议状态为可复用，HTTP/2/3 的 GOAWAY、连接错误和 peer 限制要阻止新 stream。

### 3.4 HTTP/3 和 QUIC 类型

HTTP/3 不能复用 HTTP/2 的 TCP 连接抽象。需要独立的概念：

```text
QuicConnectionId
PacketNumberSpace   Initial | Handshake | Application
QuicStreamId        双向/单向及发起方
QuicFrame           CRYPTO、STREAM、ACK、MAX_DATA、RESET_STREAM、...
QuicTransportParams 最大数据、最大 stream、idle timeout 等
QpackEncoder/Decoder 动态表、blocked stream 和最大表大小
Http3Frame          HEADERS、DATA、CANCEL_PUSH、SETTINGS、GOAWAY、...
```

QUIC 必须处理乱序 datagram、重复包、ACK range、丢包重传、拥塞窗口、idle timeout、stream reset 和 connection close。TLS 只产生握手消息与密钥更新；QUIC 负责 packet protection 和可靠 stream。该边界符合 RFC 9000、RFC 9001 和 RFC 9114 的分工。[QUIC/TLS 分层](https://www.rfc-editor.org/rfc/rfc9001.html#section-3)

## 4. 错误、取消和资源语义

### 4.1 分层错误

错误类型按产生层定义，外层只包装、不抹除原始错误：

```text
UriError
HeaderError
BodyError / BodyLimitExceeded
CodecError
Http1Error
Http2Error(stream_id?, error_code, phase)
Http3Error(stream_id?, error_code, phase)
QuicError(packet_space?, error_code, phase)
TlsError(version?, alert?, verification_stage)
TransportError(endpoint, operation, cause)
PolicyError(endpoint, operation, rule)
TimeoutError(phase, elapsed, deadline)
CancelledError(reason)
ClientError(operation, cause)
ServerError(operation, cause)
```

每个错误至少包含稳定的 machine-readable kind、阶段和可选 stream/endpoint 上下文；诊断文本用于人类阅读，不能作为程序分支条件。错误中不得包含 Cookie、Authorization、私钥、完整 URL 用户信息或 body 内容。

### 4.2 传播规则

1. 不可信字节、远端字段、证书和压缩数据只返回 typed error；禁止 `abort`。
2. 状态机错误在协议层终止对应 stream；连接级错误关闭连接并取消所有未完成 stream。
3. I/O 错误原样保留在 `TransportError` 中；policy 拒绝保持 `PolicyError`，不被重试。
4. handler 错误默认向调用者传播。只有显式提供 error responder 时，server 才把它映射为 HTTP 响应。
5. 超时分为 connect、TLS、request headers、request body、response headers、response body、idle 和 total deadline；错误必须指出阶段。
6. 取消是幂等操作。第一次取消原因保留，后续取消不覆盖原因；取消必须唤醒读、写、body queue、连接池等待和重试等待。
7. 自动重试默认只允许 GET、HEAD、OPTIONS、PUT、DELETE 或调用方明确声明幂等的请求；POST 等非幂等请求必须同时具备可重放 body 和显式策略。重试前重新评估 policy、DNS、TLS 和认证状态。

### 4.3 资源限制

所有入口都要接受或继承 `Limits`，并在实际累积前检查：

- 单行、字段数量、字段总字节和动态压缩表大小；
- 请求和响应 body、解压后的 body、缓存 body 和聚合输出；
- HTTP/2/3 stream 数量、并发请求数、待发送队列和 body queue；
- QUIC datagram、ACK range、重传队列、连接 idle 时间和总 CPU/时间预算；
- QPACK blocked stream 数量及其引用的动态表条目。

达到限制时返回稳定的 `LimitExceeded` 子类，释放相关缓冲，并按协议发送必要的 stream/connection 错误。库不提供“无限制”默认值；需要无限制时必须显式配置并承担调用方责任。

## 5. 各层实现路线

### 阶段 A：公共契约和不变量（P0）

- 冻结现有 `types/body/codec/http1/http2/service` 的兼容层，补齐构造函数、访问器、错误 kind 和 `Limits` 校验。
- 建立统一 URI、字段、日期和 authority 解析器；所有 parser 采用 `BytesView`/增量输入，拒绝越界和隐式文本转换。
- 将 `BodyStream` 的 finish/fail/cancel、消费回调和关闭行为写成可测试契约。
- 把 `abort` 限制在调用方配置错误和不可恢复的内部不变量；网络输入路径改为 typed error。

验收：现有 HTTP/1、HTTP/2 测试全部通过；任意单字节分片、空输入、重复 finish、过量 body 和错误后继续读取均有固定测试。

### 阶段 B：HTTP/1.1 生产级核心（P0）

- 完成 RFC 9110/9112 的请求/响应语义：方法、状态码、Host、CONNECT、Expect/100-continue、HEAD、1xx、204/304、升级、trailers、close-delimited 和 keep-alive。
- 严格处理 Content-Length/Transfer-Encoding 冲突、重复长度、非法 chunk、obs-fold、非法 trailer 和 request-smuggling 组合。
- 增加客户端连接复用和安全 pipeline 缓冲；一个响应 body 未消费时不得把下一个响应交给调用方。
- 将现有 `netops` 的重定向、输出和错误映射改为调用 client/service，而不是重新解析协议。

验收：curl、Wget、标准 HTTP/1 测试服务和故障注入内存 pipe 互操作；所有解析错误都不崩溃、不泄漏后台任务、不产生越界写。

### 阶段 C：HTTP/2 完整连接生命周期（P0）

- 完成 RFC 9113 的帧校验、伪头规则、SETTINGS、PING、GOAWAY、RST_STREAM、优先级兼容处理和错误码映射。
- 固化 HPACK Huffman、动态表上限、索引越界、EOS/padding、重复伪头和 header list size 行为。
- 实现连接级 reader、发送 scheduler、stream registry、双层 flow control、blocked DATA 和 response body 背压。
- 支持 prior knowledge、h2c Upgrade 和 ALPN 结果驱动；GOAWAY 后只允许已有 stream 完成。

验收：nghttp2/h2spec 类互操作、任意 frame 分片、N 个并行 stream、窗口为零、RST/GOAWAY、异常 handler 和客户端作用域关闭测试全部通过。

### 阶段 D：传输、TLS 和客户端策略（P0/P1）

- 在 `transport` 中实现 TCP/UDP/DNS/TLS 的 capability contract 和内存测试替身；Native/Wasm 适配器不得出现在协议包。
- 保留当前宿主 TLS 作为默认后端；把 SNI、ALPN、信任锚、主机名验证、客户端证书和 verify-failure 暴露为 `TlsOptions`。
- 用纯 MoonBit 的 ASN.1/PKIX/TLS 组件作为可切换后端，先完成 RFC/NIST 向量、证书负向用例、跨目标构建和独立审查，再替换宿主实现。
- 在 client 层加入 HTTP/HTTPS endpoint、HTTP proxy/CONNECT、重定向 loop detection、Authorization 跨 origin 清理、CookieJar、Basic/Digest/Bearer 和 Retry-After。
- 内容编码通过 `content_coding` 注入；解压后的字节必须再次执行 body limit。gzip/deflate/Brotli 优先，其他编码保持显式 unsupported。

验收：真实 HTTPS 服务、故意错误证书、代理认证、跨 origin 重定向、Cookie 过期、压缩 bomb、DNS/policy 拒绝和超时测试均有可重复结果。

### 阶段 E：QUIC 和 HTTP/3（P1）

- 先实现无网络 I/O 的 QUIC packet parser、varint、packet number、ACK ranges、frame state 和 RFC 9001 packet protection。
- 再实现 datagram driver、丢包检测、重传、拥塞控制、idle timeout、connection ID、路径变化和 stream flow control。
- 将 TLS 1.3 handshake message 通过 CRYPTO frame 接入 QUIC；TLS record API 不得直接用于 HTTP/3 application data。
- 实现 QPACK encoder/decoder 的动态表、blocked stream 上限和取消；完成 HTTP/3 SETTINGS、HEADERS、DATA、GOAWAY、RESET、请求/响应 stream。
- HTTP/3 协商失败必须有明确错误或受策略控制的 HTTP/2/1 fallback，不能静默改变安全策略。

验收：RFC 9000/9001/9002、RFC 9114、RFC 9204 向量和受控丢包/乱序网络；至少与一个独立 HTTP/3 实现完成 GET、POST、并发 stream、重置和连接关闭互操作。

### 阶段 F：服务端、缓存和发布硬化（P1）

- 提供 listener/acceptor 能力接口、优雅关闭、连接并发上限、请求超时、handler 取消和错误 responder。
- `cache` 只提供可插拔 RFC 9111 策略；缓存键、Vary、Age、ETag、条件请求和缓存大小由调用方配置，不把无限内存缓存藏在 client 内。
- 增加观测钩子：请求阶段、协议版本、stream id、字节数、重试次数和错误 kind；默认不记录 header 值、Cookie、Authorization 和 body。
- 固化 semver、弃用窗口、`pkg.generated.mbti` 审查、许可证/依赖清单和跨目标发布工件。

验收：长时间连接、并发压力、资源上限、优雅关闭、重复发布构建、Native/Wasm/Wasm-GC/JS 编译和文档示例全部通过。

## 6. 测试和验证体系

### 6.1 单元与性质测试

- parser 对任意输入分片、随机字节、截断、重复字段、边界整数和超长输入进行性质测试；
- Body 对 backpressure、producer/consumer 取消、finish/fail 顺序、精确长度和 trailers 做状态机测试；
- HTTP/2/3 对 stream id、窗口、动态表、ACK、重传和 GOAWAY 做模型测试；
- 使用 MoonBit QuickCheck 生成 URI、字段、chunk、frame、压缩块、证书长度和路径组合；随机生成器只负责测试，不进入生产包。

### 6.2 差分与互操作

- HTTP/1 与 curl、Wget、独立 HTTP server 做请求/响应和错误 framing 差分；
- HTTP/2 与 nghttp2 及独立 client/server 做 HPACK、窗口、并发、RST 和 GOAWAY 差分；
- TLS/QUIC 使用 RFC 向量、独立 TLS/QUIC 实现和证书测试套件；不把“自己的客户端访问自己的服务端”作为唯一证据；
- 每个发布目标记录工具链版本、源码提交、依赖版本、构建摘要和实际工件路径，避免旧二进制造成误判。

### 6.3 安全与资源测试

必须单独覆盖请求走私、字段注入、HTTP/2 connection/stream error、HPACK/QPACK 压缩炸弹、解压炸弹、证书链错误、主机名不匹配、重放风险、DNS rebinding、跨 origin Authorization 泄漏、body/queue/stream/CPU/时间限制和取消后的资源回收。

### 6.4 必过命令

在仓库根目录执行并记录结果：

```bash
moon fmt --check
moon check --target all --deny-warn --warn-list +73
moon build --target all --deny-warn --warn-list +73
moon test --target all --deny-warn --warn-list +73
moon info
moon package --list
```

Native socket 互操作、Wasm policy 测试、长时间流测试、资源限制测试和发布 smoke 必须作为额外 gate；不能用单次 `moon test` 代替。

## 7. 约定和兼容策略

- 使用 MoonBit block style，以 `///|` 分隔声明；文件按职责命名，不用一个 `misc` 文件承载跨层逻辑。
- 公共函数使用 checked error；`try!` 只用于测试 fixture 或明确允许终止的应用入口。库代码不把远端输入错误变成 `abort`。
- 原始协议数据使用 `Bytes`/`BytesView`；String 只用于已经验证为文本的字段。不要用字符串 lowercasing 代替 header token/URI 的规范化规则。
- 默认配置必须安全且有限：验证 TLS、有限 body/header/stream、有限重定向和无自动非幂等重试。放宽限制的选项使用清晰名称并写入文档。
- 不保存跨客户端的可变 Cookie、认证、缓存、连接池或动态压缩表。全局注册表只允许只读常量。
- 不在错误、日志、trace 或 metrics 中输出密钥、Authorization、Cookie、完整用户信息 URL、请求 body 或证书私钥材料。
- 新增公共类型先在拥有它的 public package 定义，再由 facade 显式 wrapper/re-export；不从 `internal` 包公开具体类型。
- 现有 `0.6.0` 调用方通过 deprecated wrapper 迁移；删除或改变 framing、错误类型和默认安全行为必须提升 major 版本，并在 `README`、`.mbti` 和 changelog 中同步说明。
- 协议版本、TLS 后端、压缩算法、代理和重试策略在结果中可观测；库不以“自动尝试所有后端”隐藏平台差异。

## 8. 生产发布门槛

只有同时满足以下条件，版本才能标记为 production：

1. Native、Wasm、Wasm-GC 和 JS 的协议核心完成构建；声明支持的传输后端均有真实或可审计的 capability 实现。
2. HTTP/1.1、HTTP/2、HTTP/3 的必需 RFC 测试、负向测试、互操作和资源限制 gate 全部通过。
3. 所有网络输入路径无未处理 `abort`；错误保留层级、阶段、stream/endpoint 上下文，取消能回收所有 task 和 buffer。
4. TLS 默认验证 peer 和 hostname；纯 MoonBit TLS 后端通过向量、证书路径、跨目标和独立审查后才可成为默认实现。
5. client 的重定向、重试、Cookie、认证、代理、解压和缓存行为有明确测试矩阵，非幂等请求不会被隐式重放。
6. 每个构建工件记录 MoonBit 工具链、依赖锁定、源码提交和构建摘要；发布 smoke 消费的就是该工件。
7. 性能基准覆盖吞吐、延迟、内存、并发 stream、背压和取消；性能回归有阈值和可重复环境说明。
8. 公共 `.mbti`、README、变更日志、许可证和安全边界与实际实现一致，并完成一次独立代码/协议安全审查。

## 9. 依赖与实现决策

### 9.1 采用的依赖

下表是本路线的默认依赖选择。版本写入 `moon.mod`，每次升级都要重新跑全目标构建、差分测试和许可证检查；不能用未锁定的最新版本替代表中版本。

| 能力 | 依赖和版本 | 引入方式与限制 |
|---|---|---|
| Unicode UCD、规范化、IDNA、Bidi、Punycode | `moonbit-community/ucd@0.5.0`、`normalization@0.5.0`、`idna@0.5.0`、`bidi@0.5.0`、`punycode@0.5.0` | Apache-2.0；只按功能包引入。数据基线为 Unicode 16.0.0，不能宣称完整 locale 排序。|
| 时区和 HTTP 日期辅助 | `caijiewei295/tzif-engine@0.1.0` | Apache-2.0；只接收调用方提供的 TZif bytes，不自行查找、下载或读取系统时区文件。|
| DEFLATE、gzip、zlib、Brotli | `moonbit-community/flate@0.7.3`、`hustcer/fbr@0.8.2` | Apache-2.0；使用无 I/O、可暂停的解码器，解压后重新执行 `max_body_bytes`。|
| Cookie 和 Public Suffix 匹配 | `mizchi/crater-browser-http@0.19.0` 的 `cookie_jar`/`psl` 包 | Apache-2.0；作为解析和匹配基础，补齐 Expires 过期、host-only、完整 PSL 和持久化策略。不得引入浏览器 JS runtime 包。|
| TLS/PKI 和密码原语（迁移阶段） | `mizchi/experimental_crypto@0.0.2`、`cc06b/mooncry@0.44.0` | 仅通过 `tls` facade 使用；保留当前宿主 TLS 为默认后端。两者都不能以测试数量代替独立安全审查；不通过审查不得标记为生产默认实现。|
| 测试随机生成 | `moonbitlang/core/quickcheck`；工具链不含所需 API 时才使用 `moonbitlang/quickcheck@0.14.0` | 只在测试包引入，不进入生产依赖；生成器必须固定种子并记录反例。|

`walkzzz/re-mbt@0.1.0` 是 HTTP 之外命令层正则/Glob 的候选，不放入 HTTP 核心依赖图。它采用 LGPL-2.1-or-later 并带 OCaml linking exception，若由上层命令引入，发布材料必须附带对应许可证文本。

### 9.2 不直接采用的候选

- `oboard/mio@0.5.4` 的 HTTP/3 仍是单请求实验路径，缺少完整证书链验证、连接级多路复用和充分的丢包恢复；可作为 QUIC 互操作参考，不作为 MoonbitHTTP 的 HTTP/3 核心。
- `Haoxincode/moonbash@0.1.0` 发布模块限定 JS，不能满足本库 Native/Wasm 协议核心的目标；其 parser 可作为 shell 项目参考，但不进入 HTTP 依赖图。
- `shina1024/jqx@0.4.2` 的核心包含 Native C locale/filesystem stub；在完成纯 MoonBit locale 和 capability 改造前，不把它作为 HTTP 或 jq 的无条件生产依赖。
- `illusory0x0/posix@0.2.2` 是 Native-only FFI，不能替代跨目标 `transport` contract；它最多用于单独的宿主 adapter 评估。

优先复用已经验证为纯 MoonBit、无不必要宿主调用的库：HTTP 编解码可从当前 MoonbitHTTP 基础继续扩展；Unicode、时间、压缩和密码算法通过上表模块接入，但都必须经过目标构建、错误行为和许可证审查。算法库的测试数量不能直接当作安全审计结论。

协议和客户端层不引入依赖来替代 capability contract。没有同时满足 Native/Wasm 目标、资源限制和错误语义的现成进程、POSIX 或 QUIC 运行时，就继续在本项目或对应的 MoonBitHTTP 子包中实现；宿主原语只存在于明确隔离的 adapter 包。

当前最重要的工程决策是：**MoonbitHTTP 负责可复用的 HTTP 协议和连接基础，cmd 负责 curl/Wget 的产品行为与沙箱策略。** 两者通过 `Request`、`Response`、`Body`、`Client` 和 capability 接口协作，不能通过复制 parser、重新解释错误或直接调用宿主网络命令协作。
