# `application/client`

[中文](README_zh.md) · [Project README](../../README.md)

Execute requests over transport capabilities supplied by your application. Use `Http1Client::send` for byte bodies with redirect, retry and cache policies. `Http1PooledRoundTripper::execute_body` streams a single exchange, including chunked uploads and trailers. Consume or cancel each response body to release the connection.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/application/client",
  "ZSeanYves/MoonbitHTTP/core/types",
}

supported_targets = "js+native+wasm+wasm-gc"
```

Add this function to a `.mbt` file in the importing package.

```moonbit
pub async fn get(client : @client.Http1Client, uri : @types.Uri) -> Bytes {
  let response = client
    .send({
      http_method: Get,
      uri,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: b"",
    })
    .unwrap_or_error()
  response.body
}
```

## Multiplexed clients

Use `with_http2_pool` for HTTP/2. HTTPS requires negotiated `h2`, and cleartext uses prior knowledge. Use `execute_body` for streaming or `execute` for a bounded byte response. For HTTP/3, pass an authenticated connection opener to `with_http3_pool` and send absolute HTTPS requests through `Http3Client::send`. The pool shares connections by origin. Finish reading or cancel streamed responses inside the pool scope.
