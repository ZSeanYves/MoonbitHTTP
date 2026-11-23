# QUIC and TLS boundary

> Status: canonical
> Scope: boundary between the portable QUIC driver and an injected TLS 1.3
> provider; this page describes implemented interfaces and explicit limits.
> Source: working-tree (governed by Git)
> Last reviewed: 2026-11-23

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

## Datagram boundaries and recovery

The raw datagram driver and the TLS driver open each QUIC packet in a coalesced
datagram in wire order. TLS processes each packet's CRYPTO data before the next
packet is opened. A server checks the complete UDP payload against the
1,200-byte minimum for client Initials. Its own Initial ACK can be shorter.
[RFC 9000 section 14.1](https://www.rfc-editor.org/rfc/rfc9000.html#section-14.1)

The receive limit advertised in `max_udp_payload_size` is capped by the
configured datagram buffer. By default it permits UDP payloads up to 65,527
bytes. Outgoing packets start with a 1,200-byte path budget. A configured
larger packet size also requires sufficient peer receive capacity. The native
HTTP/3 adapters use the same receive bound for their UDP socket and driver.
[RFC 9000 section 14](https://www.rfc-editor.org/rfc/rfc9000.html#section-14)

The send path calculates the protected wire length before checking congestion
and the path's amplification budget. Recovery charges packets that elicit an ACK
or contain PADDING, including padding inserted by the builder. The driver
retains retransmittable frames separately. ACK, loss and key retirement release
the original charge once. Standalone recovery callers pass `contains_padding`
to `on_packet_sent` when their own builder includes padding. The boolean in
`can_send(bytes, in_flight)` is true for either ACK-eliciting or padded packets.
[RFC 9002 section 2](https://www.rfc-editor.org/rfc/rfc9002.html#section-2)

Received packet numbers share a 4,096-number replay and ACK window per
encryption level. A blocked ACK stays pending for the next received packet or
timer poll. The sender uses up to 16 recent ACK ranges within its byte budget
and can include an older out-of-order trigger. Its RTT sampling keeps a bounded
history for unpadded ACKs that may be the largest packet in a mixed ACK.
[RFC 9002 section 5.1](https://www.rfc-editor.org/rfc/rfc9002.html#section-5.1)

The recovery timer uses each packet-number space's latest ACK-eliciting send
to choose the next probe. A pending time-threshold loss takes precedence and
can retransmit stream data without a second ACK. Before address validation a
client can probe with Handshake keys or a padded Initial even after the peer
acknowledges the entire flight. A blocked send preserves the probe count. The
standalone recovery API treats a returned `ProbeTimeout` as a dispatched probe.
[RFC 9002 section 6.2](https://www.rfc-editor.org/rfc/rfc9002.html#section-6.2)

The packet driver reserves 64 additional packet records per connection for
timer probes. An ordinary send uses the configured tracking limit. A probe
can retransmit the oldest retained payload in the selected space or send PING
when there is no payload. Copies share the frames and keep individual wire-byte
charges. An ACK releases the payload once. Each packet leaves congestion
accounting on ACK, detected loss or key discard. With all 64 probe records
outstanding, `poll` returns `LimitExceeded("QUIC PTO probe reserve", 64)`.
The raw driver can receive feedback and retry. Repeated timeouts alone never
declare any of those packets lost.
[RFC 9002 section 6.2](https://www.rfc-editor.org/rfc/rfc9002.html#section-6.2)

When a padded flight would consume the last ordinary slot or leave less than
1,200 bytes of congestion credit, the driver can replace one PADDING byte
with PING to elicit an ACK. An ACK-eliciting server Initial is padded to at
least 1,200 bytes and must pass path amplification admission.
[RFC 9000 section 13.2.7](https://www.rfc-editor.org/rfc/rfc9000.html#section-13.2.7)

## Dependency audit on 2026-10-01

The checked versions were `mizchi/experimental_crypto@0.0.2` and
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
