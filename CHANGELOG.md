# Changelog

## Unreleased

This worktree contains the roadmap-driven production hardening for the 0.6.x
line. The public surface now includes bounded client policy, connection pooling,
cookies, cache policy, authentication, content coding, transport/TLS contracts,
QUIC/HTTP/3 state machines, and Native capability adapters.

Notable safety behavior:

- HTTP/1 connection pools re-check policy after DNS resolution and before each
  numeric connect, keep response-body leases tied to physical sessions, and
  close sessions on cancellation or failed framing.
- Proxy-routed origins are now resolved and every numeric candidate is checked
  by `NetworkPolicy` before a forward request or CONNECT tunnel is opened;
  denied origin addresses cannot reach the proxy as a confused deputy.
- Redirects remove library-managed `Authorization` across origins; Basic,
  Bearer, and Digest state is scoped by origin, and Digest retries require a
  replayable body.
- Content decoding is bounded independently for encoded and decoded bytes, and
  stale `Content-Encoding`/`Content-Length` metadata is removed after decoding.
- QUIC `CryptoData` actions now report the CRYPTO stream offset rather than the
  enclosing packet number, preserving TLS handshake reassembly across packet
  reordering.
- HTTP/3 bounds QPACK-blocked frame memory by `max_buffer_bytes` and reclaims
  completed non-critical unidirectional stream records; QPACK encoder pending
  dynamic-section metadata is also bounded and released on ACK/cancellation.
- HTTP/2 bounds cumulative CONTINUATION header blocks, reclaims closed stream
  flow-control records, and restores connection-level capacity after a body is
  consumed from a reclaimed stream.
- Connection-pool eviction notifications are bounded by `max_total`; a full
  close-notification queue returns `AtCapacity` instead of dropping a physical
  session ID.
- BodyStream wake-up notifications are bounded to one level-triggered token;
  repeated consumption cannot accumulate an unbounded event queue.
- HTTP/3 request field sections now require a validated `:authority`, restrict
  `:scheme` to HTTP schemes, parse the method and request target, reject
  duplicate or malformed `Host`, and enforce `Host/:authority` equality.
- URI authorities now accept bracketed hosts only when they are valid IPv6 or
  RFC 3986 IPvFuture literals; malformed bracketed names are rejected before
  HTTP/2 or HTTP/3 protocol handling.
- HTTP/1 response decoders reject `Content-Length` and `Transfer-Encoding` on
  1xx, 204, and successful CONNECT responses while preserving the legal
  `Content-Length` metadata on HEAD and 304 responses.
- QUIC path validation authorizes the initial and every migrated endpoint with
  `NetworkPolicy::QuicEndpoint`; rejected candidates do not mutate path state.
  Application streams, application packets, and 0-RTT remain fail-closed until
  an established connection with installed application keys exists.
- The Native HTTP/1 convenience layer now exposes
  `new_http1_client_with_policy`, so callers can inject an explicit DNS,
  connect, redirect, and proxy policy instead of relying on `AllowAllPolicy`.
- Transport endpoints reject embedded ports and malformed bracketed hosts;
  colon-containing hosts must be valid IPv6 literals before they reach a
  resolver or connector.
- Native TLS fails closed for unsupported custom trust-anchor bytes, client
  certificate/key bytes, server handshakes, and ALPN offers other than
  `http/1.1`.

This is not a production release declaration. Native HTTP/3 interoperability,
QUIC TLS 1.3 CRYPTO integration, native certificate identity configuration,
long-run/pressure/performance thresholds, and independent protocol/security
review remain release gates.
