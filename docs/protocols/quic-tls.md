# QUIC and TLS boundary

> Status: canonical
> Scope: boundary between the portable QUIC driver and an injected TLS 1.3
> provider; this page describes implemented interfaces and explicit limits.
> Source: working-tree (governed by Git)
> Last reviewed: 2026-10-01

`QuicCryptoReassembler` in the QUIC package orders CRYPTO ranges independently
for Initial, Handshake and Application packet-number spaces. Its `CryptoData`
actions feed `QuicHandshakeInput`, which uses one `QuicHandshakeDecoder` per
encryption level. TLS handshake messages can cross CRYPTO frames, but cannot
cross encryption levels. The decoder bounds lifetime bytes and message count,
rejects non-contiguous input and becomes terminal after an error or successful
level completion.

The decoder only recognizes message framing and encryption-level legality. It
does not verify certificate identities, signatures, Finished or transport
parameters. In particular it rejects TLS KeyUpdate, EndOfEarlyData and
post-handshake authentication with `Alert(10)`. These restrictions follow
[RFC 9001 sections 4 and 6](https://www.rfc-editor.org/rfc/rfc9001.html).

`runtime/transport.QuicTlsProvider` describes the TLS engine boundary. A concrete provider
must own the transcript, (EC)DHE, certificate chain/hostname/time validation,
ALPN, transport-parameter extension and Finished verification. The interface
returns handshake bytes, directional traffic secrets and authenticated
completion metadata. Secret-bearing events intentionally omit `Debug`.

`QuicDatagramDriver.install_traffic_secret` derives packet keys and installs each
direction exactly once. It rejects Initial-level callbacks, out-of-order
application secrets, cipher-suite changes and reinstallation. Installing keys
leaves the driver in `Handshaking`. The lower-level `establish` method still
requires a caller that owns the authenticated TLS/transport-parameter workflow;
it must not be interpreted as proof that this package ran TLS.

`QuicPacketKeys.next_application_keys` implements RFC 9001's `quic ku` key
derivation while retaining the original header-protection key. Its SHA-256
derivation is checked against an independently generated OpenSSL HKDF vector.
The datagram driver's key-update state requires handshake confirmation and an
ACK of the current outgoing phase, responds to an authenticated peer update
using new outgoing keys, and retains previous receive keys for three PTOs.
Packet numbers never reset. Initial keys are discarded when Handshake CRYPTO
is exchanged; Handshake keys and their recovery state are discarded on
confirmation. Reinstallation cannot bypass those transitions.

## Installed dependency audit

The checked versions are `mizchi/experimental_crypto@0.0.2` and
`moonbitlang/async@0.20.2` from this repository's dependency installation.

- `experimental_crypto/tls13` provides key-schedule, raw-handshake and
  certificate-verification primitives. `client_handshake_1rtt_verified` consumes
  caller-supplied ClientHello, ServerHello, ECDHE shared secret and a complete
  decrypted server flight, then checks CertificateVerify, Finished, certificate
  chain, validity and DNS hostname. It is not an interactive QUIC provider.
- Its ClientHello builder exposes SNI and TLS key-exchange extensions but has no
  ALPN or QUIC transport-parameters inputs. The package has no server handshake
  engine and explicitly rejects HelloRetryRequest in its one-shot client.
- `experimental_crypto/quic` provides Initial packet protection primitives.
- `async/tls` exposes stream/record TLS client/server operations. Its public API
  has no raw QUIC handshake or traffic-secret callbacks.

The native provider uses the installed OpenSSL 3.5+ raw QUIC callback API to run
real client and server handshakes; it does not depend on either Mooncake package
having an interactive QUIC handshake implementation. `QuicTlsDriver` connects
that provider to protected CRYPTO packets and applies authenticated transport
parameters. Native regression tests verify real certificates, Finished, h3,
transport parameters, stream delivery and a wire key update. Other backends can
inject the same provider capability, but do not ship a concrete TLS engine.

Independent HTTP/3/QUIC TLS interoperability, long-duration UDP
loss/reordering/pressure testing and cross-platform native coverage remain
release gates. Deterministic fixture keys in other driver tests are not
handshake evidence. The native OpenSSL callback boundary is covered by scoped
ASan tests; that result does not replace those protocol and deployment gates.
Track the current state in [release evidence](../release/current.md) and the
complete acceptance criteria in the [roadmap](../release/roadmap.zh-CN.md).
