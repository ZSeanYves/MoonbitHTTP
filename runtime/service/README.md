# `service`

Status: canonical
Scope: public async HTTP/1 and HTTP/2 service drivers
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Connects HTTP/1 and HTTP/2 state machines to async Reader/Writer capabilities, including h2c, concurrent dispatch, backpressure, deadlines, and scoped shutdown.

## Entry points
Use serve_http1_connection, serve_http1_or_h2c_connection, serve_http2_connection, serve_auto_connection, ClientConnection, and with_h2_client_connection.

## Dependencies and targets
Depends on types, body, http1, http2, and auto. Host sockets belong to adapters; HTTP/3 service integration is not silently provided here.

## Usage
Give each service explicit Reader, Writer, handler, and validated config. Handlers use Request[BodyStream] -> Response[B]. Consume H2 response bodies inside the callback.

## Invariants and scope
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

## Canonical docs
- [Package map](../../docs/concepts/packages.md)
- [Architecture](../../docs/concepts/architecture.md)
- [Root guide](../../README.md)
