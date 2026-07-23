# MoonbitHTTP/http1

主 API 是增量 `RequestDecoder`/`ResponseDecoder` 事件模型和 framing encoder。
它保留连接 over-read 数据，支持 pipeline、定长/chunked/close-delimited body
与 trailers，并拒绝歧义 framing。异步连接请使用 `service`。
