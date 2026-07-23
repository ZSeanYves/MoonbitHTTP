# MoonbitHTTP 维护实施报告

日期：2026-07-23

## 1. 结果

Phase A-E 已全部完成。当前架构采用以下单一分层：

```text
types + body
      ^
codec <- http1/http2 pure state machines
      ^
service <- moonbitlang/async/io Reader + Writer
      ^
TCP / memory pipe / callback or uv runtime
```

所有子包直接位于模块根目录；协议 codec 与异步连接层分别由 `http1`、
`http2` 和 `service` 提供。

## 2. Phase A：类型与传输基础

已完成：

- `types` 提供验证并规范化的 `HeaderName`、字节型 `HeaderValue` 和保留顺序、
  重复值的 `HeaderMap`。
- `Request[B]` / `Response[B]` 使用泛型 body，不再由通用类型决定 body 实现。
- `body.Body` 是异步帧接口，支持 `Data`、`Trailers`、`SizeHint` 和有界收集。
- `codec.Buffer` 是纯增量缓冲，不依赖 runtime。
- `io`、`service`、`uv_adapter` 直接复用 `moonbitlang/async/io.Reader` 与
  `Writer`，没有创建竞争性的同名 trait。
- 连接层已在官方 `MemoryReader`、callback adapter 和 TCP 上验证。

## 3. Phase B：HTTP/1 connection

`http1.RequestDecoder` 和 `ResponseDecoder` 是持久连接状态机，输出：

```text
Head -> Data* -> Trailers? -> End
```

已实现：

- 任意输入分片、持久 over-read 缓冲和 pipeline 顺序；
- fixed length、chunked、response close-delimited body；
- 流式 data/trailers 事件及消费方背压；
- 重复 Content-Length 一致性检查；
- Transfer-Encoding/Content-Length 冲突拒绝；
- Host、header/body/buffer limits；
- HEAD、CONNECT 2xx、1xx、204、304 的无 body 规则；
- keep-alive、Connection: close 和 EOF/半关闭处理；
- 重复 header 的无损编码、chunked trailers 和 forbidden trailer 检查。

service 与 client 共同使用同一组持久连接状态机。

## 4. Phase C：Service、Client 与协议选择

已完成：

- `serve_http1_connection`：异步 `Request[Bytes] -> Response[Bytes]` service；
- `drive_http1_events`：不聚合 body 的低层流式/backpressure driver；
- `serve_http1_with_error_responder`：只有调用方显式提供策略时才映射错误；
- `ClientConnection.send`：握手后的顺序复用、1xx、chunked、trailers、
  close-delimited response；
- `Detector`：不消费、不重排前缀的 prior-knowledge 探测；
- 外部 ALPN 结果选择；
- 完整 h2c Upgrade：解析 `HTTP2-Settings`、发送 101、保留 over-read 字节，
  并把升级请求映射为 HTTP/2 stream 1；
- `serve_auto_connection`：统一驱动 HTTP/1、HTTP/2 prior knowledge 和 h2c。

连接池、重定向、cookie 和缓存不属于基础 `ClientConnection` 与 codec 的职责，
当前版本不提供这些高层能力。

## 5. Phase D：HTTP/2 runtime

已完成的连接级能力：

- 增量 9-byte frame decoder 和最大帧限制；
- client/server stream id 奇偶、递增和 stream 状态转换；
- 多流请求聚合与并发 service 调度；
- SETTINGS 生命周期和 initial-window 调整；
- PING ACK、GOAWAY、RST_STREAM、WINDOW_UPDATE；
- HEADERS/CONTINUATION 不可交错约束；
- 连接与流两级 flow control、容量归还和发送容量预留；
- service 响应按 peer window 分片发送，窗口耗尽时释放写锁并等待更新；
- 响应写锁，保证连接级 HPACK 顺序和每流帧顺序；
- HPACK 动态表、大小更新、header-list size 限制；
- RFC 7541 Appendix B 的全部 257 个 Huffman 码字和严格 padding/EOS 校验。

HTTP/2 server push 没有成为用户功能；收到不允许的 PUSH_PROMISE 会按协议
报错。这与原始任务中 HTTP/2 为可选项、且不要求高级服务器功能的边界一致。

## 6. Phase E：适配与质量门槛

已完成：

- `uv_adapter.CallbackTransport` 将异步 read/write/close callback 适配到官方
  I/O trait，不锁定具体 uv.mbt 版本；
- `test_support` 提供任意分片、故障 Reader 和录制 Writer；
- HTTP/1 对每一个单字节 split boundary 做回归；
- HTTP/2 frame 对每一个 header/payload split boundary 做回归；
- HPACK 使用 RFC 7541 C.4.1 官方向量；
- native benchmark 覆盖 HTTP/1 增量解析和 HPACK Huffman；
- native TCP smoke server 经 curl HTTP/1.1、nghttp2 prior knowledge 和
  nghttp2 h2c Upgrade 验证；
- CI 检查格式、四后端零警告 check/test、native async integration、真实
  socket 互操作、benchmark build 和 coverage。

## 7. 错误边界

- `types`：`HeaderError` / `UriError`；
- `codec`：`CodecError`；
- HTTP/1：`Http1Error`，区分 start-line/header/framing/limit/EOF；
- HTTP/2：`H2ProtocolError.ConnectionError` 与 `StreamError`，携带 RFC error
  code 和 stream id；
- I/O：官方 Reader/Writer 抛出的原始错误；
- 用户逻辑：service 抛出的原始错误。

连接层不会无条件捕获所有错误并固定返回 500。

## 8. 验证命令

```bash
moon fmt --check
moon check --target all --deny-warn --warn-list +73
moon test --target all --deny-warn --warn-list +73
moon build --target all --deny-warn --warn-list +73
moon bench --build-only --target native --deny-warn --warn-list +73
bash scripts/interoperability.sh
moon coverage analyze -- -f cobertura -o coverage.xml
```

验证基线：

- `moon check --target all --deny-warn --warn-list +73`：wasm、wasm-gc、JavaScript、
  native 全部通过；
- `moon test --target all --deny-warn --warn-list +73`：wasm 46/46、wasm-gc
  37/37、JavaScript 46/46、native 46/46；wasm-gc 少 9 项是工具链不支持
  async/whitebox 测试，并非测试失败；
- `moon build --target all --deny-warn`、native benchmark build、发布打包和
  `git diff --check` 全部通过；
- curl HTTP/1.1、nghttp2 prior-knowledge、nghttp2 h2c Upgrade 真实 socket
  互操作全部通过；
- Cobertura 行覆盖率为 45.05%（728/1616）。该报告后端不计入
  async/whitebox 测试。

## 9. API 与布局基线

- 子包直接位于模块根目录，包名统一使用 `lower_snake_case`；
- 文件按职责命名，测试和基准分别使用 `_test.mbt` 与 `_bench.mbt` 后缀；
- HTTP/2 帧序列化公开函数统一使用 `encode_*`；
- HPACK 只公开有状态的 `HpackContext` 与明确的 Huffman codec；
- `pkg.generated.mbti` 由 `moon info --target all` 按当前包图生成。

## 10. 协议一致性覆盖

已落实：

- RFC 9112 负例：严格十进制 Content-Length、重复值一致性、TE/CL 冲突、折叠
  header、close-delimited EOF 和 chunk framing；
- HTTP/2 负例：保留 stream bit、PADDED 帧形状、自依赖、SETTINGS 角色约束、伪头
  重复/缺失、大写 header 和 TE 语义；
- HTTP/2 流级错误发送 `RST_STREAM` 后继续处理其他流；connection error 才会终止
  连接；
- 连接/流双层 flow-control 消耗与归还、长循环压力测试、响应发送容量预留；
- ServerConfig、HTTP/2 connection 和 ClientConnection 的可选 read/write timeout
  策略，默认不启用且由 async runtime 传播错误。

当前一致性测试尚未覆盖：

- 将更多 RFC 9112 request-smuggling 语料和 h2spec 负例固化为测试；
- 使用可取消的 Reader fixture 验证取消传播和资源释放；
- 与更多独立实现做差分测试；
- parser/HPACK 的 native allocation 与 copy profiler 基线。

这些属于 conformance 与性能覆盖边界，不影响当前 package 职责划分。
