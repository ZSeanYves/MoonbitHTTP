# `adapter/native/client`

[中文](README_zh.md) · [Project README](../../../README.md)

Native only. `new_http1_client` builds a reusable client for HTTP/1.0 and HTTP/1.1 from a resolver, network policy, clock and TLS provider. The application can share it across requests and should call `close` when finished. Use `with_http2_pool` or `with_http3_pool` to share multiplexed connections within a scope.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/adapter/native/client" @native_client,
  "ZSeanYves/http/adapter/native/tls" @native_tls,
  "ZSeanYves/http/adapter/native/transport" @native_transport,
  "ZSeanYves/http/runtime/transport",
  "ZSeanYves/http/application/client",
}

supported_targets = "+native"
```

Add this function to a `.mbt` file in the importing package.

```moonbit
pub fn[P : @transport.NetworkPolicy] new_client(
  policy : P,
) -> Result[@client.Http1Client, @client.ClientError] {
  @native_client.new_http1_client(
    @native_transport.NativeResolver::new(),
    policy,
    @native_transport.NativeClock::new(),
    @native_tls.NativeTlsProvider::new(),
  )
}
```

## HTTP/3 connections

Use `with_http3_client_connection` for a single HTTPS origin or `with_http3_pool` for multiple origins. A response can arrive before the upload completes. Read or cancel it within the scope. Pass `resolver=Some(resolver)` for a named UDP peer and use the HTTPS hostname in `TlsOptions::for_quic`. Use `origin_port` when the logical port differs from the UDP port. The pool counts handshakes and draining connections toward `max_connections` and leaves replay decisions after GOAWAY to the application.

For an example using the returned client, see [sending an HTTP/1.1 request](../../../application/client/README.md).
