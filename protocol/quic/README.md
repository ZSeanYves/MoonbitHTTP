# `quic`

> Status: protocol engine
> Scope: QUIC packet protection, transport state and path actions
> Targets: JS, Native, Wasm, Wasm-GC

`quic` is an incremental protocol state machine. It consumes injected
runtime/transport TLS capabilities and emits actions for a driver; it does not create
UDP sockets. Initial, Handshake and Application packet spaces, Retry/version
negotiation and path validation remain explicit state transitions.

Completed streams release their storage and replenish the peer's stream-count and connection-byte credit. A custom transport using `QuicConnection` must reliably send the frames returned by `take_credit_updates()`. `QuicDatagramDriver::poll()` already schedules them. Receive credit is returned at stream retirement. Each open stream remains bounded by the configured per-stream byte limit.

See [the QUIC/TLS boundary](../../docs/protocols/quic-tls.md).
