# `http3`

Status: canonical
Scope: public HTTP/3 codec, state, and driver
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Implements HTTP/3 frames, fields, SETTINGS/control streams, QPACK, request streams, connection state, and QUIC stream actions.

## Entry points
Use Http3Connection, Http3Driver, frame types, QpackField, and QPACK encoder/decoder APIs.

## Dependencies and targets
Depends on types, codec, and quic; protocol-core builds target Native, Wasm, Wasm-GC, and JS, while network use needs host adapters.

## Usage
Feed QUIC stream fragments to `Http3Driver::on_stream_data` and apply its actions in order. Dispatch end-of-message processing on `Event(H3MessageFinished(id))`. If QPACK instructions arrive after a request's FIN, the driver emits its completion on the encoder-stream callback after decoding the pending fields. Requests can arrive ahead of the peer control stream and use the initial settings.

Forward QUIC `StreamReset` and `SendStopped` to `on_stream_reset` and `on_stop_sending`. A request input reset releases blocked QPACK fields. Aborting a critical stream yields `H3ClosedCriticalStream`. Local `cancel_request_stream` requests cancellation of both stream directions and emits the QPACK decoder instruction.

## Invariants and scope
Critical streams, duplicate fields, CONNECT settings gates, QPACK bounds, body lengths, and request lifecycle transitions are enforced here; sockets are outside.

## Canonical docs
- [Package map](../../docs/concepts/packages.md)
- [Architecture](../../docs/concepts/architecture.md)
- [Root guide](../../README.md)
