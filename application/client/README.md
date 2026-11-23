# `client`

> Status: public application API
> Scope: request execution, pooling and client policy over protocol drivers
> Targets: JS, Native, Wasm, Wasm-GC

`client` owns application-facing request lifecycle and connection reuse. It
receives transport capabilities and delegates framing to HTTP protocol
packages. Native socket construction belongs in [`adapter/native/client`](../../adapter/native/client/).

For a single exchange with streaming input and output, pass a `Request[B]`
where `B : Body` to `Http1PooledRoundTripper::execute_body`. HTTP/1.1 uploads
with an unknown size use chunked framing and can carry trailers. The executor
pulls the next frame after the previous write completes. Read the response to
completion or cancel its body to release the pool lease. Automatic redirect,
retry and cache policy belong to the byte-oriented `Http1Client::send` API.

Use `with_http2_client` to send requests to direct HTTP/2 origins. The pool
shares one opening or active session per origin and waits for the peer's
initial SETTINGS before admitting requests. HTTPS requires negotiated `h2`.
Cleartext origins use prior knowledge. Set `Http2PoolOptions.max_connections`
to bound physical connections, including connections draining after GOAWAY.
Call `execute_body` for streaming uploads and responses or `execute` for a
bounded byte response. Consume or cancel streamed responses inside the scope.
The scope closes its sockets and joins the connection workers on exit.

The 0.7 line is an alpha API boundary; consult [migration](../../docs/guide/migration.md)
before upgrading from 0.6.
