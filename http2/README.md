# MoonbitHTTP/http2

The primary API consists of `FrameDecoder`, `H2Connection`, `HpackContext`, and
request/response frame encoders. It supports multiplexed stream state,
SETTINGS/control frames, connection and stream flow control, the complete RFC
7541 Huffman table, dynamic HPACK, and bounded header lists. Async concurrent
service dispatch is provided by `service`.
