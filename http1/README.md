# MoonbitHTTP/http1

The primary API is the incremental `RequestDecoder`/`ResponseDecoder` event
model plus the framing encoders. It preserves connection over-read data,
supports pipelining, fixed/chunked/close-delimited bodies and trailers, and
rejects ambiguous message framing. Use `service` for async Reader/Writer
connections.
