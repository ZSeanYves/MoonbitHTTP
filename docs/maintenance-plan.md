# MoonbitHTTP 0.6.0 维护实施报告

日期：2026-07-23

## 1. 当前架构

```text
types + body
      ^
codec <- http1/http2 incremental state machines
      ^
service <- moonbitlang/async/io Reader + Writer
      ^
TCP / memory pipe / callback runtime
```

所有包位于模块根目录。`types` 持有协议无关的泛型
`Request[B]`/`Response[B]`；`body` 持有统一的异步 body 抽象；`http1`、
`http2` 只负责协议状态机和帧编码；`service` 负责传输驱动和错误边界。

## 2. 0.6.0 流式 API

- `BodyStream` 使用有界异步队列，默认容量为 8；`push` 在队列满时挂起，
  `finish` 表示正常结束，`fail` 保留原始终止错误。
- `ServerConfig` 统一控制所有 server 入口的 limits、读写超时、有界 body 队列和
  `close_callback`；`body_queue_capacity` 同时作用于 HTTP/1、h2c 和 HTTP/2。
- `serve_http1_connection`、`serve_http1_or_h2c_connection`、
  `serve_http2_connection` 和 `serve_auto_connection` 的 handler 统一为
  `Request[BodyStream] -> Response[B]`，其中 `B : Body`。
- HTTP/1 `ClientConnection::send` 接受任意 `Body`，返回 `Response[BodyStream]`。
- HTTP/2 client 使用 `with_h2_client_connection(reader, writer, run, config?)`；
  作用域内部 reader pump、多路 stream、request producer 和 response dispatcher
  由同一个 task group 管理。`H2Client::send` 在 response HEADERS 到达后返回，
  response body 通过 bounded `BodyStream` 逐 frame 消费。
- 高层 service/client 只使用泛型 `Request[B]`、`Response[B]` 和
  `Response[BodyStream]`，底层 codec 仍可按需使用字节专家 API。

`FullBody` 适合已知长度的小 body；`QueueBody` 适合固定 frame 序列；
`BodyStream` 用于协议连接与 producer/consumer 并发。`body.collect` 是调用方
显式选择的有界聚合工具，不是 service 的隐式行为。

## 3. HTTP/1

`RequestDecoder` 和 `ResponseDecoder` 持续输出：

```text
Head -> Data* -> Trailers? -> End
```

已实现任意输入分片、over-read/pipeline 缓冲、Content-Length、chunked、
close-delimited response、trailers、HTTP/1.0/1.1 keep-alive、HEAD/CONNECT/1xx/
204/304 body 规则，以及 Host/header/body/buffer 限制。

高层 response framing 由 body `SizeHint` 决定：精确长度使用
Content-Length；HTTP/1.1 未知长度使用 chunked；HTTP/1.0 未知长度使用
close-delimited 并关闭连接。长度不一致、非 chunked trailers、重复 trailers
或 trailers 后继续 DATA 均返回 `Http1Error.InvalidFraming`。

HTTP/1 server 在单连接内保持顺序响应。handler 提前完成后，driver 会继续消费
当前 request 的剩余协议帧，不再向无人消费的 body queue 写入。

## 4. HTTP/2

已实现增量 frame decoder、HPACK 动态表/Huffman、SETTINGS、PING、GOAWAY、
RST_STREAM、WINDOW_UPDATE、stream id/state、HEADERS/CONTINUATION 约束及连接/
stream 双层 flow control。

HTTP/2 server 在收到 HEADERS 后立即分派 `Request[BodyStream]`。每个 stream 有
有界 body queue 和一个 blocked-DATA 槽位；队列满时不返还窗口，控制帧仍由连接
reader 继续处理。消费者取得 DATA 后才发送 WINDOW_UPDATE。response 按 peer
window 分片发送，窗口为零时等待 WINDOW_UPDATE 信号；trailers 使用 trailing
HEADERS，body 或 handler 失败发送 `RST_STREAM(CANCEL)`。

`with_h2_client_connection` 负责 client preface、SETTINGS、HPACK 上下文、stream
id、GOAWAY/RST、并发 slot、连接/stream flow control 和 reader pump。多个
`send` 可以在 callback 作用域内并发运行；GOAWAY 后禁止新 stream，已有 stream
继续完成。callback 结束时未消费的 response body 以取消错误关闭，不保留 detached
reader task。

## 5. 协议一致性与错误

仓库内测试固定覆盖：

- HTTP/1 Content-Length/Transfer-Encoding 冲突、重复长度、非法十进制、
  obs-fold、chunk size/CRLF、forbidden trailer 和 request-smuggling 组合；
- HTTP/2 reserved stream bit、frame size、padding/priority、SETTINGS 角色约束、
  stream id、WINDOW_UPDATE、RST/GOAWAY、HPACK Huffman/EOS 和伪头语义；
- 任意单字节 split boundary、bounded `BodyStream`、HTTP/1 双向 trailers、
  HTTP/2 多 stream server/flow-control，以及 HTTP/2 client 内存回环。

错误边界保持为：I/O 错误原样传播；HTTP/1 使用 `Http1Error`；HTTP/2 使用带
error code/stream id 的 `H2ProtocolError`；用户 handler 错误仅在显式
`serve_http1_with_error_responder` 中转换。

## 6. 验证命令

```bash
moon fmt --check
moon check --target all --deny-warn --warn-list +73
moon test --target all --deny-warn --warn-list +73
moon build --target all --deny-warn --warn-list +73
moon bench --build-only --target native --deny-warn --warn-list +73
bash scripts/interoperability.sh
moon coverage analyze -- -f cobertura -o coverage.xml
moon info
```

0.6.0 本地基线：wasm 55/55、wasm-gc 37/37、JavaScript 55/55、native
55/55。
`pkg.generated.mbti` 由 `moon info` 生成；service 接口只暴露 Body trait、
`BodyStream`、泛型 response 和作用域化 H2 client。
