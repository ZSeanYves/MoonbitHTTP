# `application/client`

[中文](README_zh.md) · [Project README](../../README.md)

Send logical requests with `Client::send`. A scoped client shares authentication, cookies and cache across requests. Portable hosts supply a single-exchange function, wall and monotonic clocks and redirect authorization to `with_client`. Native applications can use the [native factory](../../adapter/native/client/README.md).

Add these imports to `moon.pkg`.

```moonbit
import {
  "ZSeanYves/http/application/client",
  "ZSeanYves/http/core/body",
  "ZSeanYves/http/core/types",
}

supported_targets = "js+native+wasm+wasm-gc"
```

```moonbit
pub async fn get(client : @client.Client, uri : @types.Uri) -> Bytes {
  let request = client.request(Get, uri, @client.Upload::bytes(b""))
  let response = client.send(request)
  let (data, _) = @body.collect(response.body, max_bytes=1024 * 1024)
  data
}
```

Use `Upload::once(body)` for a single-use stream or `Upload::reopen(factory)` to produce the same entity on each actual send. Reading frames preserves backpressure and trailers. Cancel the response body when stopping early.

Redirects, retries, authentication and caching share one client. Cache entries commit after complete consumption. Decoding and integrity failures terminate the body. Digest `auth-int` responses are buffered up to the configured body limit and verified before delivery. The total deadline extends through response consumption.

For a range download, leave `Accept-Encoding` unset or choose it explicitly. A 206 response carries the selected representation’s bytes and `Content-Range`, so offsets still apply when assembling multiple ranges.

For direct protocol control, the H1 and H2 pool methods `execute_body` and the H3 pool method `Http3Client::send` execute a single exchange.

Use `response.body.read_batch(64)` to request up to 64 frames in one read. It waits for that count, trailers, or EOF. A trailing header frame is included once. An empty array marks EOF. Use `next_frame()` when an individual frame should be delivered as soon as it arrives. Single and batch reads may alternate within the same client scope.

### Request lifecycle

| Public operation | HTTP/1 | HTTP/2 and HTTP/3 |
| --- | --- | --- |
| Send headers on a ready session | The header write has its own deadline. | One deadline covers stream admission and the complete header write. |
| Upload or receive content | A stalled read or write consumes the corresponding body budget. An interrupted message retires the connection. | A stalled producer, stream write or body read consumes its stage budget. Cancellation releases the stream. Other streams can continue. |
| Await response headers | The final response head completes the phase. A timeout ends this exchange. | The final response head completes the phase. A timeout resets the request stream. |
| Begin graceful server shutdown | The handler already admitted finishes. Idle keep-alives wake, and buffered later requests are skipped. | The server drains accepted streams and stops admission. |
| Inspect a redirect or trailers | The default returns the original response. Explicit rejection raises a redirect error. Buffered H1 and H2 exchanges expose initial headers and trailers separately. | The same redirect policies apply. Streaming callers consume trailers through the body interface. |

DNS and TCP connect have separate budgets on TCP paths. H3 has DNS and a QUIC/TLS handshake budget. H2/H3 wait for a ready pooled connection before starting the request-header stage. The total budget begins at the logical send and includes remaining response consumption. The Native H1 transport also honors `idle_ms` on socket reads and writes. A stage timeout carries the corresponding `ClientPhase` in `ClientTimeout`.

## HTTP/2 pool limits

`Http2PoolOptions.max_connections_per_origin` defaults to 1. Set it to 2 to let short requests use a second connection when every ready connection for their origin has exhausted its local or peer stream limit. Concurrent callers share outstanding dials. Opening, ready, and draining connections all count toward `max_connections`. An accepted stream can drain across GOAWAY while the pool replaces its retired connection. The Native client factory takes the same optional per-origin limit for HTTP/2.
