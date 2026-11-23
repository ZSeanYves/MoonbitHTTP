# `service`

Status: canonical
Scope: async HTTP/1, HTTP/2 and HTTP/3 connection drivers
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## Purpose
Connects HTTP/1 and HTTP/2 state machines to async Reader/Writer capabilities, including h2c, concurrent dispatch, backpressure, deadlines, and scoped shutdown.

## Entry points
Use serve_http1_connection, serve_http1_or_h2c_connection, serve_http2_connection, serve_auto_connection, ClientConnection, and with_h2_client_connection.

## Dependencies and targets
HTTP/3 uses the portable HTTP/3 and QUIC drivers, a dedicated datagram socket, a clock and a QUIC TLS provider. Host sockets come from adapters.

## Usage
Give each service explicit Reader, Writer, handler, and validated config. Handlers use Request[BodyStream] -> Response[B]. Consume H2 response bodies inside the callback.

`with_http3_connection` owns the socket and calls the application after the authenticated handshake. Submit requests or responses through `io.session`, and read ordered application event batches with `io.next_events()`. `io.flush()` sends pending writes. The scope runs a receiver and a recovery timer, and keeps at most one unread batch in its delivery queue. On a normal return, the scope waits for queued stream writes and their QUIC acknowledgments, sends HTTP/3 close and releases the socket. `shutdown_timeout_ms` bounds the drain and final send. An orderly peer close preserves already delivered batches. The next read after the last batch reports the close. The caller owns the TLS provider.

## Invariants and scope

For portable server shutdown, share an `H3ServerShutdown` across calls to `with_http3_connection` through the `server_shutdown` argument. Calling `begin()` stops admission in each typed handler loop and sends GOAWAY. The caller owns the grace deadline. A failing established scope attempts to send an HTTP/3 application close within `shutdown_timeout_ms`.

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

`serve_http3_connection(io, handler)` dispatches one task per admitted request. The handler shares the HTTP/1 and HTTP/2 streaming request/response signature. An individual handler failure resets its stream. After an early response it stops the upload with `STOP_SENDING(H3_NO_ERROR)`. Supply `on_request_error` to observe individual handler errors. `with_h3_client` uses the same I/O scope for concurrent typed client requests. It keeps completed response bodies readable while the application finishes consuming them.

## Canonical docs
- [Package map](../../docs/concepts/packages.md)
- [Architecture](../../docs/concepts/architecture.md)
- [Root guide](../../README.md)

`H2Client::send` waits for both local capacity and the peer's concurrent-stream allowance. A SETTINGS increase can resume a waiting request. GOAWAY or connection shutdown wakes waiters with an error, and cancelling a request while waiting for response headers resets its open stream.
