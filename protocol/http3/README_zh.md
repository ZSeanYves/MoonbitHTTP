# `http3`

Status: canonical
Scope: public HTTP/3 codec, state, and driver
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
实现 HTTP/3 frame、字段、SETTINGS、控制流、QPACK、request stream、connection state 和 QUIC stream action。

## 入口
入口是 Http3Connection、Http3Driver、frame 类型、QpackField 以及 QPACK encoder/decoder。

## 依赖与目标
依赖 types、codec、quic；协议核心面向四目标，联网仍需宿主 adapter。

## 使用边界
将 QUIC 流片段传给 `Http3Driver::on_stream_data`，按顺序处理返回的动作。收到 `Event(H3MessageFinished(id))` 后再结束对应 HTTP 消息。如果请求 FIN 先于所需的 QPACK 指令到达，驱动会在编码流回调中解出剩余字段，并通知原请求已完成。请求流先于对端控制流到达时使用初始设置。

将 QUIC 的 `StreamReset` 和 `SendStopped` 分别交给 `on_stream_reset` 和 `on_stop_sending`。请求接收方向被复位时会释放阻塞的 QPACK 字段，关键流中止会产生 `H3ClosedCriticalStream`。本地 `cancel_request_stream` 会请求取消两个传输方向，并生成 QPACK 解码器指令。

## 不变量与范围
统一检查 critical stream、重复字段、CONNECT gate、QPACK、body 长度和 request 生命周期；不做 socket。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
