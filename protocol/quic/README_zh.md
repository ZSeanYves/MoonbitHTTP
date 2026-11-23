# `quic`

Status: canonical
Scope: public QUIC packet, recovery, path, and driver
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## 用途
提供 QUIC packet/frame codec、connection/path state、transport parameters、丢包恢复、Retry/version、key phase 和 TLS/datagram driver。

## 入口
入口是 QuicDatagramDriver、QuicTlsDriver、QuicConnection、QuicRecovery、QuicTransportParameters、QuicRetryTokenManager。

## 依赖与目标
依赖 types、transport、portable tls，面向四目标协议核心。

## 使用边界
显式传入 role、endpoint、limits、clock、entropy、TLS；输入 datagram/timer 并执行 action。

## 不变量与范围
packet space、frame legality、amplification、路径验证、Retry、丢包、并发 stream 和 key phase 是状态不变量；不解析 hostname、不打开 UDP。

应用接收 `StreamData` 中的字节后，调用 `consume_stream_data(stream_id, count)`，每个字节只计一次。消费会释放接收存储，同时推进流和连接的字节窗口。推迟消费即可对活动流施加背压。接收端遇到 RESET 时会按最终大小归还剩余额度。两个方向都结束后，连接释放该流剩余的存储并补回对端的流数量额度。

`QuicDatagramDriver::poll()` 负责发送窗口更新，驱动收到包确认后会释放发送端对应字节的额度。自定义传输层在握手中通告 `local_transport_params()`，可靠发送 `take_credit_updates()` 返回的帧，并通过 `acknowledge_stream_data(stream_id, offset, length)` 报告已确认的 STREAM 字节区间。

非阻塞发送可用 `QuicDatagramDriver::send_stream_prefix`。调用方发出返回的数据报，按返回的字节数推进游标，保留余下的数据，在后续收包或计时器回调时续写。发送受阻时偏移保持不变，只有最后一段携带 FIN。

## 规范文档
- [中文总览](../../README_zh.md)
- [包地图](../../docs/concepts/packages.md)
- [架构](../../docs/concepts/architecture.md)
