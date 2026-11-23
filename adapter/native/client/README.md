# `adapter/native/client`

> Status: Native adapter
> Scope: explicit resolver, policy, clock and TLS client construction
> Targets: Native only

This adapter is the Native entry point for `client`. It requires all network
capabilities as constructor arguments and performs policy checks before a
socket connect. It does not define portable protocol state.

Use `new_http1_client` for HTTP/1 and `with_http2_client` for a scoped
HTTP/2 pool. Supply the resolver, policy, clock and TLS provider to either
entry point. The HTTP/2 pool limits and timeouts are in `Http2PoolOptions`.

See [`adapter/native/transport`](../transport/) and [`adapter/native/tls`](../tls/)
for the injected providers.
