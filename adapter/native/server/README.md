# `adapter/native/server`

> Status: Native adapter
> Scope: Native server socket and capability wiring
> Targets: Native only

This package connects `server` lifecycle to Native sockets, resolver/policy,
clock and TLS providers. Policy is evaluated before network resources are
created; portable protocol packages stay independent of this adapter.

Use `NativeTcpListener::bind_http_tls` to serve HTTP requests with an
async handler. The listener routes negotiated `h2` to the HTTP/2 driver and
`http/1.1` to HTTP/1.1. A peer without ALPN can use HTTP/1.1 when the
listener offers that protocol. Pass the resulting listener to
`ServerSupervisor::serve` to manage active connections and shutdown.

After a successful exchange the listener flushes the provider's close notification. `shutdown_timeout_ms` bounds the flush (default 1,000 ms). Handler failure or cancellation closes the transport immediately.

`NativeHttp3Listener::bind` accepts a numeric UDP endpoint, network policy, TLS 1.3 options with h3 ALPN, and a per-connection handler. Call `serve(supervisor)` on the bound listener. QUIC Initial retransmissions are associated with their source and original destination ID. Established connections use cryptographically generated 16-byte server IDs. Each peer has a bounded datagram queue. A full queue drops that peer's datagram and leaves recovery to QUIC. `begin_shutdown` on the supervisor stops admission while existing peers can still receive acknowledgments and finish their responses. A handler owns the per-connection event loop and dispatches application requests by stream ID.

Use `NativeHttp3Listener::bind_http` for an application handler taking `Request[BodyStream]` and returning `Response[B]`. The request carries HTTP/3, the origin-form target and a normalized Host header. A response may stream the request body directly, including trailers. Request body buffering is bounded per stream, and QUIC grants further body credit as the handler consumes bytes.
