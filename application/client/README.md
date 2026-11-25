# `application/client`

[中文](README_zh.md) · [Project README](../../README.md)

Send logical requests with `Client::send`. A scoped client shares authentication, cookies and cache across requests. Portable hosts supply a single-exchange function, wall and monotonic clocks and redirect authorization to `with_client`. Native applications can use the [native factory](../../adapter/native/client/README.md).

```moonbit
pub async fn get(client : @client.Client, uri : @types.Uri) -> Bytes {
  let request = client.request(Get, uri, @client.Upload::bytes(b""))
  let response = client.send(request)
  let (data, _) = @body.collect(response.body, max_bytes=1024 * 1024)
  data
}
```

The example imports `application/client`, `core/types` and `core/body`. Use `Upload::once(body)` for a single-use stream or `Upload::reopen(factory)` to produce the same entity on each actual send. Reading frames preserves backpressure and trailers. Cancel the response body when stopping early.

Redirects, retries, authentication and caching share one client. Cache entries commit after complete consumption. Decoding and integrity failures terminate the body. Digest `auth-int` responses are buffered up to the configured body limit and verified before delivery. The total deadline extends through response consumption.

For direct protocol control, the H1 and H2 pool methods `execute_body` and the H3 pool method `Http3Client::send` execute a single exchange.

Use `response.body.read_batch(64)` to request up to 64 frames in one read. It waits for that count, trailers, or EOF. A trailing header frame is included once. An empty array marks EOF. Use `next_frame()` when an individual frame should be delivered as soon as it arrives. Single and batch reads may alternate within the same client scope.
