# `tls`

> Status: protocol and capability contract
> Scope: portable TLS handshake inputs, QUIC crypto levels and errors
> Targets: JS, Native, Wasm, Wasm-GC

`tls` defines portable handshake and key-schedule boundaries used by QUIC and
stream transports. Certificate identity and platform credentials are supplied
by an injected provider; the Native implementation lives in [`adapter/native/tls`](../../adapter/native/tls/).

Packet protection uses OpenSSL 3 EVP on Native and the experimental portable implementation on Wasm, Wasm-GC and JS. The Native QUIC handshake requires OpenSSL 3.5 or later.
