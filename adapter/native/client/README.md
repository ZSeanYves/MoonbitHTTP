# `adapter/native/client`

> Status: Native adapter
> Scope: explicit resolver, policy, clock and TLS client construction
> Targets: Native only

This adapter is the Native entry point for `client`. It checks the supplied network policy before connecting.

Use `new_http1_client` for HTTP/1 and `with_http2_client` for a scoped
HTTP/2 pool. Supply the resolver, policy, clock and TLS provider to either
entry point. The HTTP/2 pool limits and timeouts are in `Http2PoolOptions`.

`with_http3_connection` takes a numeric UDP endpoint, policy, TLS options and an application callback. Use `TlsOptions::for_quic(origin_host)` for authenticated TLS 1.3 with h3 ALPN. The scope creates random connection IDs, owns the UDP socket and OpenSSL provider, and serves multiple request streams on the same connection. `H3ConnectionIo` provides the session and event reader.

See [`adapter/native/transport`](../transport/) and [`adapter/native/tls`](../tls/)
for the injected providers.
