# MoonbitHTTP 0.5.0 维护实施报告

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

## 2. 0.5.0 流式 API

- `BodyStream` 使用有界异步队列，默认容量为 8；`push` 在队列满时挂起，
  `finish` 表示正常结束，`fail` 保留原始终止错误。
- `ServerConfig.body_queue_capacity` 控制 HTTP/1 request body 队列容量。
- `serve_http1_connection`、`serve_http1_or_h2c_connection`、
  `serve_http2_connection` 和 `serve_auto_connection` 的 handler 统一为
  `Request[BodyStream] -> Response[B]`，其中 `B : Body`。
- HTTP/1 `ClientConnection::send` 和 HTTP/2
  `H2ClientConnection::send` 接受任意 `Body`，返回 `Response[BodyStream]`。
- 旧的高层 `Request[Bytes]`、`Response[Bytes]` 和 `ClientResponse` 已删除，
  不提供兼容别名。

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

`H2ClientConnection` 负责 client preface、SETTINGS、HPACK 上下文、stream id、
GOAWAY/RST 和 request/response frame 编解码。当前公开 `send` 对同一传输执行
串行驱动，以保证只使用 `moonbitlang/async` 公开的结构化并发 API 时不存在孤儿
reader task；response 仍通过统一的 `BodyStream` 类型交付。需要真正多 stream
并发 reader pump 的下一步 API 应由调用方提供 `TaskGroup` 生命周期，或等待
async runtime 提供公开的可持有 background task handle。

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

0.5.0 本地基线：wasm 49/49、wasm-gc 37/37、JavaScript 49/49、native
49/49。`pkg.generated.mbti` 由 `moon info` 生成；`service` 接口中不再存在高层
`Request[Bytes]`、`Response[Bytes]` 或 `ClientResponse`。
