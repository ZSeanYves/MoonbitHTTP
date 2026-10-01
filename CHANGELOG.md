# Changelog

## 0.7.0 — development

Breaking architecture migration from 0.6. This is an alpha worktree, not a
production release declaration. The original behavior baseline and source
snapshot are recorded in [`docs/archive/2026-09/v1-baseline-2026-09-29.md`](docs/archive/2026-09/v1-baseline-2026-09-29.md).

- Move Endpoint and IP addresses into `core/types`; validated URI, authority and
  header objects cannot be forged through public record construction.
- Consolidate all injected capabilities, including stream and QUIC TLS, in
  `runtime/transport`. Separate pure TLS primitives from Native OpenSSL adapters under
  `adapter/native/tls`.
- Remove the unused `io` facade and duplicate nonpooled HTTP/1 round tripper.
  Native client construction requires explicit resolver, policy, clock and
  TLS provider; numeric connectors never perform hidden hostname resolution.
- Make `BodyStream::new` return a checked result. Keep terminal state in one
  enum, preserve the first failure, and isolate body framing in HTTP/1.
- Split HTTP/1, HTTP/2, QUIC and HTTP/3 source by codec, state and driver
  responsibility. Move shared Huffman coding to `core/codec`, reuse immutable
  lookup tables, and remove the HTTP/3-to-HTTP/2 dependency.
- Propagate HTTP/2 peer table limits into the send HPACK encoder; serialize
  dynamic-table mutation with wire writes. Advertise local decoder limits.
- Validate classic and extended HTTP/3 CONNECT through one field validator;
  apply the appropriate endpoint's SETTINGS before encoding or accepting
  extended CONNECT.
- Enforce QUIC frame legality by packet space and connection phase. Require
  authenticated peer transport parameters and application keys before opening
  streams. Model path validation as challenge/response output actions.
- Add bounded CRYPTO reassembly, a real TLS 1.3 traffic-secret driver, packet
  key updates, and key retirement. Native QUIC TLS uses OpenSSL 3.5+ callbacks.
- Support Native TLS CA bytes, client and server credentials, ALPN, mTLS and
  structured certificate failures. Add certificate negative cases and ASan
  validation for the Native boundary.
- Add policy-controlled Native UDP listeners. Reject unauthorized endpoints
  before socket creation and detect oversized datagrams without silent truncation.
- Generate and check the actual package dependency graph. Replace shell
  interoperability automation with mandatory-tool `.mbtx` runners, execute
  release benchmarks, and require a clean Git snapshot for release packaging.
- Pin the CI MoonBit toolchain, check generated interfaces and architecture
  drift, verify OpenSSL selection on Linux/macOS/Windows, and retain coverage,
  package and interoperability artifacts without making Codecov availability a
  fork-pull-request gate.

Validation results and remaining production gates are maintained separately in
[`docs/release/current.md`](docs/release/current.md),
[`docs/release/gates.md`](docs/release/gates.md), and the production roadmap.
Passing unit tests does not replace independent interoperability, platform,
long-duration load, performance-threshold or security-review evidence.
