# MoonbitHTTP/service

Async HTTP connection drivers over `moonbitlang/async/io.Reader` and `Writer`:
HTTP/1, HTTP/2, h2c/prior-knowledge auto selection, concurrent HTTP/2 service
dispatch, explicit error response policy, and HTTP/1/HTTP/2 client connections.
High-level handlers receive `Request[BodyStream]` and return
`Response[B]` where `B : Body`; no byte-aggregating compatibility API remains.
`ClientConnection::new` validates four phase deadlines (request headers/body,
response headers/body), each defaulting to 30 seconds. `ServerConfig` accepts
read/write idle timeouts in milliseconds. Passing `None` explicitly selects
unbounded I/O where supported. HTTP/2 response DATA is scheduled against connection and stream
flow-control windows. Request DATA is released back to the peer only when the
consumer takes it from the bounded body queue. HTTP/1 selects Content-Length,
chunked, or close-delimited framing from `SizeHint` and protocol version.
