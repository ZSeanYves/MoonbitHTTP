# `http3`

Status: canonical
Scope: public HTTP/3 session, codec, and state machines
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## Purpose
Implements HTTP/3 frames, fields, SETTINGS/control streams, QPACK, request streams, connection state, and QUIC stream actions.

## Entry points
Use Http3Connection, Http3Driver, frame types, QpackField, and QPACK encoder/decoder APIs.

## Dependencies and targets
Depends on types, codec, and quic; protocol-core builds target Native, Wasm, Wasm-GC, and JS, while network use needs host adapters.

## Connection sessions

Create one `Http3Session` per `QuicTlsDriver`. Give the session exclusive use of QUIC application streams. Feed the results of TLS `start`, `on_datagram` and `poll` to `advance`. Transmit each returned `Transport(SendDatagram(...))`, including datagrams accompanying `Failed`. Continue polling while the connection is idle.

Request-stream DATA is delivered incrementally. A large frame may yield multiple `H3DataReceived` events. The standalone `Http3FrameDecoder` returns complete frames.

A client calls `start_request(fields, fin=true)` for a bodyless request. A server receives `Message(H3HeadersReceived(...))` and can send its response before the upload completes. Both sides can queue DATA, trailers and FIN using `send_data`, `send_headers` and `finish`. Call `advance([], now_ms)` after application writes. A full output queue preserves the stream position for retry. Stream resets and stops remain directional; `cancel` aborts both directions. The owner handles UDP routing, socket lifetime and handshake failures.

## Usage
Feed QUIC stream fragments to `Http3Driver::on_stream_data` and apply its actions in order. Dispatch end-of-message processing on `Event(H3MessageFinished(id))`. If QPACK instructions arrive after a request's FIN, the driver emits its completion on the encoder-stream callback after decoding the pending fields. Requests can arrive ahead of the peer control stream and use the initial settings.

Forward QUIC `StreamReset` and `SendStopped` to `on_stream_reset` and `on_stop_sending`. A request input reset releases blocked QPACK fields. Aborting a critical stream yields `H3ClosedCriticalStream`. Local `cancel_request_stream` requests cancellation of both stream directions and emits the QPACK decoder instruction.

## Invariants and scope
Critical streams, duplicate fields, CONNECT settings gates, QPACK bounds, body lengths, and request lifecycle transitions are enforced here; sockets are outside.

`Http3WriteBlocked` permits retry after further transport progress. A frame larger than the entire write budget raises `Http3LimitExceeded`. Call `defer_body_credit` for a pull-driven consumer and `consume_body(id, bytes_read)` as it reads or discards DATA. QUIC framing and the critical streams continue to receive credit.

## Canonical docs
- [Package map](../../docs/concepts/packages.md)
- [Architecture](../../docs/concepts/architecture.md)
- [Root guide](../../README.md)
