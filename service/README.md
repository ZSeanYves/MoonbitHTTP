# MoonbitHTTP/service

Async HTTP connection drivers over `moonbitlang/async/io.Reader` and `Writer`:
HTTP/1, HTTP/2, h2c/prior-knowledge auto selection, concurrent HTTP/2 service
dispatch, explicit error response policy, and an HTTP/1 client connection.
`ServerConfig` and `ClientConnection::new` accept optional read/write idle
timeouts in milliseconds; unset values preserve the runtime's unbounded IO
behavior. HTTP/2 response DATA is scheduled against connection and stream
flow-control windows, with control frames serialized separately.
