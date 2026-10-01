# `quic`

> Status: protocol engine
> Scope: QUIC packet protection, transport state and path actions
> Targets: JS, Native, Wasm, Wasm-GC

`quic` is an incremental protocol state machine. It consumes injected
runtime/transport TLS capabilities and emits actions for a driver; it does not create
UDP sockets. Initial, Handshake and Application packet spaces, Retry/version
negotiation and path validation remain explicit state transitions.

See [the QUIC/TLS boundary](../../docs/protocols/quic-tls.md).
