# `quic`

> Status: protocol engine
> Scope: QUIC packet protection, transport state and path actions
> Targets: JS, Native, Wasm, Wasm-GC

`quic` is an incremental protocol state machine. It consumes injected
runtime/transport TLS capabilities and emits actions for a driver; it does not create
UDP sockets. Initial, Handshake and Application packet spaces, Retry/version
negotiation and path validation remain explicit state transitions.

After accepting bytes from a `StreamData` event, call `consume_stream_data(stream_id, count)` once for those bytes. Consumption releases receive storage and advances both byte windows. Delaying consumption applies backpressure on an active stream. A receive reset returns the remaining final-size credit. Once both directions finish, the connection releases any remaining storage and replenishes the peer's stream-count credit.

`QuicDatagramDriver::poll()` sends pending window updates, and the driver releases outstanding send bytes on packet acknowledgement. A custom transport advertises `local_transport_params()` during the handshake, reliably sends frames from `take_credit_updates()` and reports acknowledged STREAM ranges with `acknowledge_stream_data(stream_id, offset, length)`.

For nonblocking writes, `QuicDatagramDriver::send_stream_prefix` returns the accepted byte count and its datagram. Keep the remaining bytes until a later receive or timer callback. A blocked write preserves its offset and a final write carries FIN only on the last portion.

See [the QUIC/TLS boundary](../../docs/protocols/quic-tls.md).
