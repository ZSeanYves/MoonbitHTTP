# `adapter/native/tls`

[中文](README_zh.md) · [Project README](../../../README.md)

Native only. `NativeTlsProvider` runs TLS over an existing byte stream with OpenSSL 3.x. `NativeQuicTlsProvider` handles QUIC handshakes with OpenSSL 3.5 or later in the 3.x series. Pass the peer identity, ALPN, trust anchors and any credentials in `TlsOptions` at handshake time. The stream provider constructor controls use of OpenSSL’s default trust paths.

For an HTTPS request with a private CA, the Native client guide shows where to pass the PEM when opening the client. [HTTPS client example](../client/README.md)

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/adapter/native/tls" @native_tls,
  "ZSeanYves/http/runtime/transport",
}

supported_targets = "+native"
```

Add this function to a `.mbt` file in the importing package.

```moonbit
pub async fn secure(
  stream : @transport.StreamConnection,
  host : String,
) -> @transport.SecureConnection {
  let tls = @native_tls.NativeTlsProvider::new()
  tls.client_handshake(
    stream,
    @transport.TlsOptions::defaults().for_server_name(host),
  ).unwrap_or_error()
}
```

## Trust sources

With peer verification enabled, an explicit nonempty PEM in `trust_anchors` replaces OpenSSL’s default roots. With `trust_anchors=None` and `allow_system_roots=true`, the provider calls `SSL_CTX_set_default_verify_paths` on the OpenSSL library loaded by the process. The library distribution and its configuration determine the CA file, hashed CA directory and any platform store integration. Set `SSL_CERT_FILE` to a PEM bundle or configure `SSL_CERT_DIR` as an OpenSSL hashed directory before starting the process. Each connection uses a fresh verification context.

On Linux use the paths for the selected distribution or pinned build. On macOS check the selected Homebrew OpenSSL prefix. On Windows check the distribution selected through `OPENSSL_ROOT_DIR`. To make an enterprise CA portable across installations, pass its PEM explicitly. Importing a root into Keychain or the Windows certificate store alone depends on the selected OpenSSL distribution. Use its matching `openssl version -a` to inspect build defaults.

## Peer verification and shutdown

Use `TlsOptions.revocation_lists` for PEM CRLs and `require_crl` to require chain revocation checks. A server can staple a DER OCSP response via `ocsp_response`. A client can require a valid staple via `require_ocsp`. Verification uses the supplied response locally. After your final write, call `SecureConnection::finish` to send the local close notification. Use `close` for immediate teardown.
