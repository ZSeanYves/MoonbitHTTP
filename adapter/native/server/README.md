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
