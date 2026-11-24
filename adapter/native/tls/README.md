# `adapter/native/tls`

[中文](README_zh.md) · [Project README](../../../README.md)

Native only. `NativeTlsProvider` runs TLS over an existing byte stream with OpenSSL 3.x. `NativeQuicTlsProvider` handles QUIC handshakes with OpenSSL 3.5 or later in the 3.x series. Pass the peer identity, ALPN, trust anchors and any credentials in `TlsOptions` at handshake time. The stream provider constructor controls use of system trust roots.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/adapter/native/tls" @native_tls,
  "ZSeanYves/MoonbitHTTP/runtime/transport",
}

supported_targets = "+native"
```

Add this function to a `.mbt` file in the importing package.

```moonbit
pub async fn secure(
  stream : @transport.StreamConnection,
  host : String,
) -> Result[@transport.SecureConnection, @transport.TlsError] {
  let tls = @native_tls.NativeTlsProvider::new()
  tls.client_handshake(
    stream,
    @transport.TlsOptions::defaults().for_server_name(host),
  )
}
```

## Peer verification and shutdown

Use `TlsOptions.revocation_lists` for PEM CRLs and `require_crl` to require chain revocation checks. A server can staple a DER OCSP response via `ocsp_response`. A client can require a valid staple via `require_ocsp`. Verification uses the supplied response locally. After your final write, call `SecureConnection::finish` to send the local close notification. Use `close` for immediate teardown.
