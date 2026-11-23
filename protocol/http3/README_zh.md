# `http3`

Status: canonical
Scope: public HTTP/3 session, codec, and state machines
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## 用途
实现 HTTP/3 frame、字段、SETTINGS、控制流、QPACK、request stream、connection state 和 QUIC stream action。

## 入口
入口是 Http3Connection、Http3Driver、frame 类型、QpackField 以及 QPACK encoder/decoder。

## 依赖与目标
依赖 types、codec、quic；协议核心面向四目标，联网仍需宿主 adapter。

## 连接会话

每个 `QuicTlsDriver` 创建一个 `Http3Session`，将该连接的 QUIC 应用流交给会话统一分配。把 TLS 的 `start`、`on_datagram`、`poll` 返回的动作传给 `advance`，发送所有 `Transport(SendDatagram(...))` 数据报，包括与 `Failed` 同批返回的关闭包。连接空闲时也需要驱动计时器。

请求流上的 DATA 会分段交付，一个大帧可产生多个 `H3DataReceived` 事件。独立使用 `Http3FrameDecoder` 时仍然按完整帧读取。

客户端用 `start_request(fields, fin=true)` 发起无正文请求。服务端收到 `Message(H3HeadersReceived(...))` 即可开始响应。两端均可通过 `send_data`、`send_headers`、`finish` 分段写正文、尾部字段和 FIN，入队后调用 `advance([], now_ms)`。队列满时可以在原位置重试。对端的复位和停止发送分别作用于对应方向，主动调用 `cancel` 会终止双向传输。调用方负责 UDP 路由、套接字生命周期及握手失败的清理。

## 使用边界
将 QUIC 流片段传给 `Http3Driver::on_stream_data`，按顺序处理返回的动作。收到 `Event(H3MessageFinished(id))` 后再结束对应 HTTP 消息。如果请求 FIN 先于所需的 QPACK 指令到达，驱动会在编码流回调中解出剩余字段，并通知原请求已完成。请求流先于对端控制流到达时使用初始设置。

将 QUIC 的 `StreamReset` 和 `SendStopped` 分别交给 `on_stream_reset` 和 `on_stop_sending`。请求接收方向被复位时会释放阻塞的 QPACK 字段，关键流中止会产生 `H3ClosedCriticalStream`。本地 `cancel_request_stream` 会请求取消两个传输方向，并生成 QPACK 解码器指令。

## 不变量与范围
统一检查 critical stream、重复字段、CONNECT gate、QPACK、body 长度和 request 生命周期；不做 socket。

写队列暂时已满时会返回 `Http3WriteBlocked`，传输取得进展后可原样重试。单帧超过整个队列容量时返回 `Http3LimitExceeded`。按需读取正文时调用 `defer_body_credit`，在读取或丢弃 DATA 后调用 `consume_body(id, bytes_read)`，帧头和关键流的流控额度会继续归还。

服务端通过 `Http3Session::send_goaway(first_rejected)` 在控制流上发送停机边界。调用方选择一个高于所有可能已处理请求的客户端双向流 ID，后续 GOAWAY 可以降低边界。收到第一帧后，客户端停止创建请求，边界以下已打开的流仍可完成。[HTTP/3 连接停机](https://www.rfc-editor.org/rfc/rfc9114.html#section-5.2)

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
