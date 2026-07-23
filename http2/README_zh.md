# MoonbitHTTP/http2

主 API 是 `FrameDecoder`、`H2Connection`、`HpackContext` 和请求/响应帧编码器。
它支持多流状态、SETTINGS/控制帧、连接与流两级 flow control、完整 RFC 7541
Huffman 表、动态 HPACK 和 header-list 限制。异步并发 service 调度位于
`service`。
