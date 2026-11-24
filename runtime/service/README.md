# `service`

Status: canonical
Scope: async HTTP/1, HTTP/2 and HTTP/3 connection drivers
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## Purpose
Connects HTTP/1 and HTTP/2 state machines to async BinaryReader/BinaryWriter capabilities, including h2c, concurrent dispatch, backpressure, deadlines, and scoped shutdown.

## Entry points
Use serve_http1_connection, serve_http1_or_h2c_connection, serve_http2_connection, serve_auto_connection, Http1ClientConnection, and with_http2_client_connection.

## Dependencies and targets
HTTP/3 uses the portable HTTP/3 and QUIC drivers, a dedicated datagram socket, a clock and a QUIC TLS provider. Host sockets come from adapters.

## Usage
Give each service explicit BinaryReader, BinaryWriter, handler, and validated config. Handlers use Request[BodyStream] -> Response[B]. Consume H2 response bodies inside the callback.

`with_http3_connection` owns the socket and calls the application after the authenticated handshake. Submit requests or responses through `io.session`, and read ordered application event batches with `io.next_events()`. `io.flush()` sends pending writes. The scope runs a receiver and a recovery timer, and keeps at most one unread batch in its delivery queue. On a normal return, the scope waits for queued stream writes and their QUIC acknowledgments, sends HTTP/3 close and releases the socket. `shutdown_timeout_ms` bounds the drain and final send. An orderly peer close preserves already delivered batches. The next read after the last batch reports the close. The caller owns the TLS provider.

## Invariants and scope

HTTP/1.1, HTTP/2 and HTTP/3 servers send `100 Continue` for pending uploads when requested. An unsupported expectation receives a final `417` before the handler runs. The HTTP/1.1 client waits up to one second for an explicit continue, subject to its response-header deadline. A final response received during that wait cancels the upload.

For portable server shutdown, share a `ServerShutdown` across calls to `with_http3_connection` through the `server_shutdown` argument. Calling `begin()` stops admission in each typed handler loop and sends GOAWAY. The caller owns the grace deadline. A failing established scope attempts to send an HTTP/3 application close within `shutdown_timeout_ms`.

Reader tasks, body queues, flow-control release, deadlines, cancellation, and close are scoped to the service call.

After the read loop observes HTTP/2 peer EOF, finite responses may finish using available send credit.
`ServerConfig.h2_eof_drain_timeout_ms` bounds this drain across handlers, response
body producers and writers (default 30000 ms, must be positive), including h2c
upgrades. Expiry raises an H2 connection `Cancel` error and cancels and joins the
remaining tasks. Disabling read/write timeouts does not disable this deadline.
The timer starts only when EOF is observed. Explicitly disabling write timeouts
still allows a control-frame write to block the read loop before that point.
Cancellation is cooperative: application code must yield and keep protected
cleanup finite. Callers constructing a full `ServerConfig` literal must add the
new field, or use `..ServerConfig::defaults()`.

`serve_http3_connection(io, handler)` dispatches one task per admitted request. The handler shares the HTTP/1 and HTTP/2 streaming request/response signature. An individual handler failure resets its stream. After an early response it stops the upload with `STOP_SENDING(H3_NO_ERROR)`. Supply `on_request_error` to observe individual handler errors. `with_http3_client_connection` uses the same I/O scope for concurrent typed client requests. It keeps completed response bodies readable while the application finishes consuming them.

## Canonical docs
- [Root guide](../../README.md)

`Http2ClientConnection::send` waits for both local capacity and the peer's concurrent-stream allowance. A SETTINGS increase can resume a waiting request. GOAWAY or connection shutdown wakes waiters with an error, and cancelling a request while waiting for response headers resets its open stream.

Call `Http3ConnectionIo::rotate_local_connection_id()` to ask the peer to switch destination IDs on the live QUIC connection. The native adapters enable issuance automatically. A portable socket owner can enable it on the datagram driver before starting the connection. [Connection ID lifecycle](../../protocol/quic/CID-SUPPORT.md)
