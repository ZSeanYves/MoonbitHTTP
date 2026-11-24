# `adapter/native/client`

> Status: Native adapter
> Scope: explicit resolver, policy, clock and TLS client construction
> Targets: Native only

This adapter is the Native entry point for `client`. It checks the supplied network policy before connecting.

Use `new_http1_client` for HTTP/1 and `with_http2_pool` for a scoped
HTTP/2 pool. Supply the resolver, policy, clock and TLS provider to either
entry point. The HTTP/2 pool limits and timeouts are in `Http2PoolOptions`.

`with_http3_pool(resolver, policy, run)` accepts absolute HTTPS requests for multiple origins. Each origin gets a separately verified connection. Use `tls` to select trust anchors and client credentials. Setting `tls.server_name` restricts requests to that hostname. `max_connections` defaults to 32 and includes handshakes and draining connections. A request that loses admission to GOAWAY is never automatically replayed.

`with_http3_connection` takes a numeric UDP endpoint, policy, TLS options and an application callback. Use `TlsOptions::for_quic(origin_host)` for authenticated TLS 1.3 with h3 ALPN. The scope creates random connection IDs, owns the UDP socket and OpenSSL provider, and serves multiple request streams on the same connection. `Http3ConnectionIo` provides the session and event reader.

`with_http3_client_connection` supplies a typed `Http3ClientConnection` for one verified HTTPS origin. `send(request)` returns `Response[BodyStream]` as soon as final headers arrive, while the request body can still be uploading. Read or cancel each response inside the scope. The default origin uses the TLS hostname and UDP peer port. Set `origin_port` if the logical HTTPS port differs. The client rejects a different origin and omits proxy credentials on this direct connection.

For a UDP hostname, pass `resolver=Some(resolver)` to `with_http3_client_connection` and supply the HTTPS origin's identity in `TlsOptions::for_quic`. The client checks the lookup policy before DNS and the endpoint policy before opening each socket. Candidate addresses follow resolver order and share the handshake time budget. Certificate failure ends the handshake. After authentication the application callback runs once. `resolve_options` controls DNS time and the maximum number of returned addresses examined.

See [`adapter/native/transport`](../transport/) and [`adapter/native/tls`](../tls/)
for the injected providers.
