# Native TLS

`NativeTlsProvider` uses the stable OpenSSL 3 API with separate memory BIOs.
OpenSSL performs the handshake, record protection, certificate chain/validity
and identity verification. MoonBit pumps bytes through the injected
`StreamConnection`; the provider performs no DNS resolution or socket creation.

Configuration is explicit and stays in memory:

- `trust_anchors` contains a PEM CA bundle. When present it replaces system
  roots. `allow_system_roots=false` requires explicit roots for verification.
- `client_certificate` and `client_private_key` contain the client PEM identity.
- `server_certificate` and `server_private_key` contain the server PEM identity.
- On the server, `verify_peer=true` requires a verified client certificate;
  set it to `false` for ordinary TLS without mutual authentication.
- Certificate-chain validation covers trust anchors, validity periods, key
  usage, hostname/IP SAN identity and key matching. CRL/OCSP revocation is not
  silently inferred from the system store and has no public option in this
  release; applications requiring revocation must reject or rotate credentials
  before constructing a provider.
- `alpn` is sent and negotiated by OpenSSL. Server order determines preference;
  no common protocol fails. A peer omitting ALPN is accepted only when HTTP/1.1
  is among the configured protocols. `h3` ALPN on a stream is only a TLS feature
  test; it does not turn TCP into QUIC.
- Minimum and maximum TLS versions are enforced before the handshake. Early
  data remains disabled. Renegotiation and session caching are disabled.

`NativeFailure` preserves the operation, OpenSSL error code, X.509 verification
code and original diagnostic. Errors and cancellation close the owned session.
Explicit synchronous `close()` aborts the connection; it is not a graceful
TLS close-notify exchange.

The loader requires OpenSSL 3 (`libssl.so.3` on Linux, Homebrew OpenSSL 3 on
macOS, or the OpenSSL 3 DLLs on Windows). It resolves the runtime once per
process and keeps the module loaded while external TLS handles exist. Windows
accepts an absolute `OPENSSL_ROOT_DIR` installation (its `bin` directory is
searched with the DLL directory as the dependency root). When that variable is
set, a missing or incomplete installation fails closed instead of falling back
to another DLL directory. Without it, the normal system DLL search locations
are used. An unavailable runtime returns `Unsupported`; there is no bundled TLS
implementation.

`NativeQuicTlsProvider` requires OpenSSL 3.5 or newer and uses its
[third-party QUIC TLS callbacks](https://docs.openssl.org/3.5/man3/SSL_set_quic_tls_cbs/).
It reuses the same CA, certificate, private-key, hostname and ALPN configuration,
but exchanges raw TLS 1.3 handshake messages rather than TLS records. It requires
`h3`, disables 0-RTT, and supports AES-128-GCM/SHA-256 and AES-256-GCM/SHA-384.
The bounded callback queues emit directional traffic secrets and CRYPTO bytes.
Completion is emitted only after OpenSSL verifies Finished, negotiates h3 and
receives the peer transport-parameter extension; certificate success alone is
not completion. The QUIC driver decodes and binds those authenticated parameters
to the observed connection IDs before establishing its connection.

`QuicTlsDriver[NativeQuicTlsProvider]` integrates these events with real QUIC
packet protection, CRYPTO reassembly, retransmission and key-phase updates.
Native tests run a real client/server certificate handshake over protected QUIC
packets, then exchange stream bytes and update keys. That in-process integration
is separate from independent implementation interoperability and UDP stress
validation. Windows and OpenSSL versions without the callback API return
`Unsupported`.

The Ubuntu CI job builds OpenSSL 3.5.8 LTS from its checksum-pinned upstream
archive using `scripts/install_ci_openssl.mbtx`, then sets both
`OPENSSL_ROOT_DIR` and `LD_LIBRARY_PATH` for subsequent native checks and tests.
It does not replace the OS OpenSSL. A cached
installation is checked with `openssl version -a` before reuse. On macOS, install
a current `openssl@3` Homebrew formula and verify its version is at least 3.5.
On Windows, install the OpenSSL 3 x64 package and set `OPENSSL_ROOT_DIR` to
its installation directory before running native tests.

The TCP tests exercise local sockets, custom trust, DNS/IP identities, invalid
trust and expiry, TLS version constraints, h2/h3 ALPN, and mutual TLS. Certificate
fixtures and their regeneration command are documented in `testdata/README.md`.

OpenSSL references: [memory BIO](https://docs.openssl.org/3.0/man3/BIO_s_mem/),
[BIO ownership](https://docs.openssl.org/3.0/man3/SSL_set_bio/),
[ALPN](https://docs.openssl.org/3.0/man3/SSL_CTX_set_alpn_select_cb/),
[peer verification](https://docs.openssl.org/3.0/man3/SSL_CTX_set_verify/).
