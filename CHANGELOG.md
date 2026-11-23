# Changelog

This file is the version-level record of user-visible and maintainer-relevant
changes. Entries are ordered newest first. A version reconstructed from module
history is marked explicitly; a Git commit date is not a Mooncakes publication
date. Raw security scans, coverage, benchmark windows and package archives stay
in local or CI workspaces and are not part of this file.

## Unreleased

- HTTP/1, HTTP/2 and HTTP/3 servers grant `100 Continue` for pending uploads and return `417 Expectation Failed` before dispatch for unsupported expectations. HTTP/1 and HTTP/2 now release the response producer without reading it for `HEAD`, `204` and `304`. HTTP/2 clients and servers share outgoing body length and trailer checks. Buffered and streaming encoders share header construction.

- Honor explicit `Expect: 100-continue` on HTTP/1.1 uploads with a bounded wait, body cancellation on early final responses and safe pool eviction. HTTP/1 and h2c servers share expectation handling and preserve buffered body bytes when selecting a protocol. HTTP/1-only connections accept read buffers below the HTTP/2 initial receive window.

- Recognize QUIC stateless resets on active paths and release HTTP/3 requests and UDP routes. Pooled requests retain the transport error when the connection worker exits. Accept larger peer datagrams during the handshake while retaining the default 1,200-byte outgoing path budget.

- Issue and rotate local QUIC connection IDs on native HTTP/3 clients and listeners. Keep one spare, retain the old route until peer retirement, and continue active streams on the replacement. The portable driver accepts explicit entropy and route callbacks. Its lifetime issuance budget defaults to 256 IDs.

- Add a scoped HTTP/3 pool for absolute HTTPS requests. HTTP/2 and HTTP/3 share origin reservation, cancellation and connection limits. Requests retain their response bodies while the pool drains GOAWAY. Concurrent waiters for one new origin evict a single idle connection from a full pool. The native factory resolves and verifies each origin independently.

- Accept UDP hostnames in the native typed HTTP/3 client through an explicit resolver. HTTP/1, HTTP/2 and HTTP/3 share DNS deadlines, ordered numeric candidates and result bounds. The HTTP/3 client can try another permitted address before authentication, while certificate failure and application errors propagate to the caller.

- Keep QUIC recovery moving when ordinary packet tracking is full. Timer probes have a separate 64-packet limit and reuse retained frames. An ACK releases shared data once, while recovery accounts for every packet copy. Padded flights elicit feedback before exhausting available credit.

- Recover QUIC time-threshold losses during a timer poll. Probe deadlines follow the last ACK-eliciting send in each eligible packet-number space. Clients can advance an unconfirmed handshake after their Initial flight was acknowledged, and a blocked probe preserves its retry interval. Repeated outbound probes allow a silent connection to reach its idle timeout.

- Account for explicit and automatic QUIC PADDING at its full wire size. Cumulative ACKs cover received ranges and survive send backpressure. Raw and TLS drivers share coalesced datagram parsing. Congestion and path admission now run before packet encryption. Callers that build their own packets can pass `contains_padding` to `QuicRecovery::on_packet_sent`. Construct live recovery state with `QuicRecovery::new` so its bounded packet history is initialized.

- Preserve a peer's orderly close when it arrives just before the HTTP/3 server starts draining. The supervisor records the connection as completed.

- Send a QUIC close-only packet even when the recovery queue is full. The closing frame no longer occupies a retransmission slot or waits for an acknowledgment.

- Bound QUIC frame encoding across an entire batch. Out-of-range integers and invalid ACK ranges return errors through the public codec. Single and batch encoders share a writer. The codec enforces stream count, token and connection ID bounds in both directions. Packet validation enforces the sender role for NEW_TOKEN and HANDSHAKE_DONE.

- Drain typed HTTP/3 servers with GOAWAY on supervisor shutdown. Idle connections close, previously admitted responses finish, and new requests receive a retryable rejection. Preserve the distinction between QUIC transport and application close codes, including the HTTP/3 normal close and bounded failure notification on cancellation.

- Add a typed, multiplexed HTTP/3 client bound to one verified HTTPS origin. HTTP/2 and HTTP/3 clients share request target and pseudo-field construction. A server can end an upload with `STOP_SENDING(H3_NO_ERROR)` after an early response. Cancelling a duplex exchange releases its slot while the connection continues serving other requests.

- Serve streaming `Request[BodyStream]` and `Response[B]` through the HTTP/3 listener. Receive credit follows application consumption, and `Http3WriteBlocked` distinguishes queue backpressure from a frame that can never fit.

- Add a shared-UDP HTTP/3 listener with connection-ID routing, per-peer queues and supervised admission and shutdown. Orderly QUIC close preserves application events already delivered to a slow response consumer.

- Add a scoped HTTP/3 client over native UDP and OpenSSL, and a portable single-peer I/O loop that drives TLS, HTTP/3 events and QUIC recovery. The interoperability runner now exercises the MoonBit client against the upstream aioquic server with `--reverse`.

- Stream incoming HTTP/3 DATA in bounded chunks, accept legal wider frame varints on fragmented input, and share frame header parsing across decoder entry points. The incremental decoder now keeps its backing storage private. Its `feed`, `next` and `finish` methods retain their signatures.
- Add a transport-driven HTTP/3 client/server session with streaming messages, bounded write queues, cancellation and per-request QPACK replay isolation. The native interoperability server now uses this public API.

- Coalesce HTTP/2 receive credit while the server writer is busy. In-flight window updates for finished streams are ignored, and a valid upload burst no longer consumes the control queue with repeated credit notifications.

- Collect body chunks with bulk copies and deliver each collection failure to its producer once, preserving the original cause.
- Fix HTTP/1 line limits across fragmented CRLF and consumed prefixes. The shared codec buffer now bulk-copies byte ranges when receiving or returning data.
- Share HTTP/2 and HTTP/3 regular-field rules across readers and writers. Both protocols reject `TE` in responses and trailers, and accept case-insensitive `trailers` in requests.
- Flush TLS `close_notify` after a successful native server exchange, including HTTP/1.0 streaming responses. Shutdown has a configurable deadline and cancellation releases the socket immediately.
- Serve HTTP/1.1 and HTTP/2 through a native TLS listener selected by ALPN. HTTP/1 servers now finish a closing exchange before processing another request and explicitly acknowledge HTTP/1.0 persistence.

- Add a bounded, origin-managed HTTP/2 client for streaming and byte requests, including a native TCP entry point. It shares DNS, policy and TLS dialing with HTTP/1, requires `h2` for HTTPS, and drains accepted streams after GOAWAY.

- Queue HTTP/2 client requests when the peer lowers its concurrent stream allowance. Resume them on capacity changes and release queued or active uploads on cancellation or shutdown.

- Handle QUIC stream cancellation in both directions. HTTP/3 releases blocked request input and treats critical-stream cancellation as a connection error. Custom QUIC transports now report acknowledged FIN and reset frames using `acknowledge_stream_frame` to replenish stream-count credit.

- Add one-shot streaming uploads to the pooled HTTP/1 executor, with the response lease retained until EOF or cancellation.
- Preserve representation framing fields on HEAD and 304 responses and leave tunnel bytes available after successful CONNECT.
- Accept a server's HTTP/2 ENABLE_PUSH setting of zero. Ignore undefined frame flags and reserved stream-ID bits. Share header-fragment validation across frame and connection decoding.
- Slide active QUIC byte windows as applications consume data and packets are acknowledged. Receive resets release their final-size credit, and completed streams return their stream-count credit. Custom transports can exchange the same limits and credit updates as the built-in datagram driver.
- Advance stream send offsets only after datagram admission. Local stream resets now use the recorded final size.
- Expose partial QUIC stream writes, preserve pending HTTP/3 responses through congestion, and wait for handshake completion before processing received 1-RTT packets.
- Accept HTTP/3 requests ahead of peer SETTINGS and emit a validated message completion event after any blocked QPACK fields have been decoded.
- Verify a 4 KiB HTTP/3 upload across a 256-byte stream window and 256 requests on one connection with an initial eight-stream allowance using aioquic.

## 0.7.0 — 2026-10-07

Mooncakes published the alpha package from the contents verified at `0967034`.
The archive SHA-256 is `f7e3d2891f5e1ed943039f6438f396f77877c8d0045ef1fe5b06b068767477fa`.

### Breaking changes

- Continue the 0.7 protocol and lifecycle hardening line. The working tree may
  change public generated interfaces before the release revision is frozen.
- Release evidence and distribution checks require a clean, reviewed Git tree;
  local edits cannot be presented as a published archive.

### Added

- README feature and target-support matrices for Native, Wasm/Wasm-GC and JS.
- A chronological history index and phase completion records for release work.
- A standard-library Go `net/http` H1/H2 reference fixture and runner. It
  reports an explicit `not_run` result when Go is unavailable and never uploads
  raw windows.
- A release-document boundary that retains generated architecture references,
  release gates and packaging rules while excluding `_build` and coverage
  outputs from distribution.

### Changed

- CI still runs tests, coverage generation, packaging checks and interoperability
  checks, but no longer uploads raw validation artifacts or sends coverage to
  Codecov.
- `docs/release/current.md`, `gates.md` and `packaging.md` now describe stable
  evidence scope instead of requiring local `_build` paths.
- Historical archive files remain immutable; their dates, revisions and
  absorption into the current changelog are indexed separately.

### Fixed

- Keep the Native TLS white-box revocation helper in the published
  `internal/test_support` tree. Its former `repo-tools` location was excluded
  from the archive, so `moon publish` failed when checking the extracted module.
- Check every distribution in an isolated extracted directory on all four
  targets, in addition to verifying the inventory and frozen Git contents.
  This check also runs through the existing CI release-evidence gate.
- The current remediation index records local fixes and regression coverage for
  the 25 deduplicated roots from the failed deep-scan records. This is not a
  claim that the scans reached complete coverage.

### Security

- Focused lifecycle, protocol, TLS, cache, cookie, content-coding and QUIC
  regressions remain covered by the current four-target test matrix.
- Closed the candidate-review paths for initial h2c EOF cleanup, mixed QUIC
  CID/PATH response admission, and control-frame writes when the write timeout
  is explicitly disabled. Each path has a focused regression and is included
  in the post-fix CI run; cooperative cancellation and partial scan coverage
  remain separate limitations.

### Performance

- Existing MoonBit old/current and Native socket comparisons remain the scoped
  local baselines. Go `net/http` is an external reference, not a threshold.
- The release CI measured the Go baseline. A paired comparison against MoonbitHTTP remains open.

### Validation

- Clean revision `201e7ae` passed hosted CI run `37516695805`: Native 514/514,
  Wasm 455/455, JavaScript 455/455 and Wasm-GC 324/324; the async integration
  suite passed 92/92 and Native TLS passed 131/131 on Ubuntu, macOS and Windows.
  The run also passed package evidence, interoperability, benchmarks and
  ephemeral coverage generation.

### Known limitations

- The two latest deep scans ended in failed/partial states (429/403) and do not
  provide a complete release-revision security conclusion.
- Public-network capacity, cross-platform deployment, online OCSP retrieval,
  browser networking and generic HTTP/3 application service remain outside the
  0.7 alpha claim.

#### Phase completion record before publication

- Status: committed and CI-verified; not a release
- Recorded at: `2026-10-06T12:54:08+08:00`
- Source revision: `201e7ae9dccbf6f7a35642673795bf968199de2a`
- Commit range: `391e415..201e7ae` for the final cleanup and documentation record
- Validation summary: clean local and hosted package evidence and CI `37516695805` passed; Go H1/H2 external comparison remains not run
- Known limitations: partial security scan coverage, no tag, and no Mooncakes publication record

## 0.7.0-alpha

Architecture and protocol-hardening line, reconstructed from module history
(`a877c70`, `2026-10-01`) and subsequent repository commits. No Git tag or
Mooncakes publication timestamp was found.

### Breaking changes

- Move public packages to the `core`, `protocol`, `runtime`, `application`,
  `policy` and `adapter` namespace layout.
- Replace implicit transport behavior with explicit capability contracts and
  checked constructors; package moves change import identity.
- Remove the legacy `io` facade and duplicate non-pooled HTTP/1 round-tripper.

### Added

- HTTP/1.1, HTTP/2, HTTP/3 and QUIC codec/state/driver separation.
- Streaming body ownership, bounded queues, backpressure and cancellation.
- Native TCP/UDP, resolver, clock and OpenSSL stream/QUIC TLS adapters.
- Certificate identity, mTLS, offline CRL and stapled OCSP validation paths.
- Architecture, distribution and release-evidence tools with generated package
  dependency references.

### Changed

- HPACK/QPACK, SETTINGS, CONNECT, QUIC packet-space, path-validation and
  connection-ID state now enforce protocol phase and resource limits.
- CI pins the MoonBit toolchain and checks generated interfaces and architecture
  drift.

### Fixed

- HTTP/2 flow-control credit, body cancellation, EOF drain and h2c lifecycle
  ownership; QPACK ordering/size accounting; QUIC key retirement and recovery;
  Native TLS credential and peer-identity error handling.

### Security

- Added malformed-input, certificate-negative, revocation, cancellation and
  resource-limit regressions across the protocol and adapter boundaries.

### Performance

- Preserved low-level decoder and Native socket old/current comparisons with
  fixed workloads and AB/BA windows. Results are scoped local evidence.

### Validation

- Four-target builds/tests, Native TLS suites, real-socket H1/H2/h2c cases and
  bounded H3/QUIC loopback controls were introduced or refreshed.

### Known limitations

- HTTP/1 and HTTP/2 have the broadest application coverage. Generic HTTP/3
  client/server service integration is not part of this alpha.
- Wasm and JS require host-provided network/TLS capabilities. Complete security
  scan coverage and clean-revision publication evidence remain gates.

#### Phase completion record

- Status: architecture/protocol line recorded as alpha development state
- Recorded at: `2026-10-01T12:03:07+08:00` (source history record)
- Source revision: `a877c70b03af0e59631489a9d2333e2a75c44926`
- Commit range: `de84bb1..391e415` for the later hardening and validation records
- Validation summary: see [current validation facts](docs/release/current.md)
- Known limitations: historical partial scan coverage and dirty working-tree evidence

## 0.6.0

Protocol library contract, reconstructed from module history. Source revision:
`aa69847db7c03a3107e741ee9f2d53ae7ad91db3` (`2026-07-23`). No publication tag
was found.

### Breaking changes

- Adopt the protocol-library contract that became the basis for the later v1
  architecture migration.

### Added

- Documented HTTP/1.1 and HTTP/2 protocol, service and transport boundaries.
- Consolidated protocol behavior and public package expectations for the 0.6
  line.

### Changed

- Updated module version and maintenance-plan scope from the 0.5 streaming
  contract.

### Fixed

- No separate fix list is recoverable from the version commit alone; later 0.7
  history supersedes this contract.

### Security

- Security properties were recorded as design requirements; no independent
  release scan or publication evidence is attributed to this reconstructed entry.

### Performance

- No version-specific performance result is recoverable from the module history.

### Validation

- Contract and package documentation were updated in the source revision.

### Known limitations

- This is a history reconstruction, not proof of a published Mooncakes artifact.

#### Phase completion record

- Status: history reconstructed
- Recorded at: `2026-07-23T14:45:13+08:00` (source commit time)
- Source revision: `aa69847db7c03a3107e741ee9f2d53ae7ad91db3`
- Commit range: source contract commit only; no release tag found
- Validation summary: protocol contract documentation changed
- Known limitations: publication date and complete runtime behavior are unknown

## 0.5.0

Streaming API contract, reconstructed from `307b3b8cb6e57ef398e637ccd19f18c1ecd7ab92`
(`2026-07-23`). No publication tag was found.

### Breaking changes

- Streaming body and service contracts became the compatibility boundary for
  the following protocol line.

### Added

- Documented streaming body, service and backpressure concepts.

### Changed

- Updated module version and shortened the maintenance plan around the streaming
  contract.

### Fixed

- No separate version-specific fix list is recoverable from the version commit.

### Security

- No independent security evidence is attributed to this reconstructed entry.

### Performance

- No version-specific performance result is recoverable from the module history.

### Validation

- Source documentation and generated package interfaces were updated.

### Known limitations

- History does not prove a registry publication or complete cross-target support.

#### Phase completion record

- Status: history reconstructed
- Recorded at: `2026-07-23T12:48:42+08:00` (source commit time)
- Source revision: `307b3b8cb6e57ef398e637ccd19f18c1ecd7ab92`
- Commit range: source contract commit only; no release tag found
- Validation summary: streaming API contract documentation changed
- Known limitations: publication date and complete runtime behavior are unknown

## 0.4.0

Root package architecture, reconstructed from `eae6ed7259b37285fd6dc69e7131945732929eec`
(`2026-07-23`). No publication tag was found.

### Breaking changes

- Reorganized the repository from the legacy `src` layout into root protocol,
  service, transport, type and adapter packages.

### Added

- Initial root package architecture, HTTP/1.1 and HTTP/2 package boundaries,
  service drivers, transport contracts and generated interfaces.

### Changed

- Removed the legacy source tree and updated CI, examples and package metadata.

### Fixed

- No separate version-specific fix list is recoverable from the version commit.

### Security

- The architecture established explicit transport boundaries; no independent
  security evidence is attributed to this reconstructed entry.

### Performance

- No version-specific performance result is recoverable from the module history.

### Validation

- The source revision added package tests, conformance fixtures and CI checks.

### Known limitations

- History does not prove a registry publication or complete target coverage.

#### Phase completion record

- Status: history reconstructed
- Recorded at: `2026-07-23T11:31:17+08:00` (source commit time)
- Source revision: `eae6ed7259b37285fd6dc69e7131945732929eec`
- Commit range: architecture commit only; no release tag found
- Validation summary: root package architecture and CI contract introduced
- Known limitations: publication date and later hardening are outside this entry

## 0.1.0

Initial module state, reconstructed from `0322d269f0bef4953fd4d003f910b30e048c28ad`
(`2025-08-24`). No publication tag or Mooncakes publication record was found.

### Breaking changes

- None recoverable from the initial commit.

### Added

- Initial MoonBit module metadata, library package, smoke entry point and basic
  unit test.

### Changed

- None recoverable from the initial commit.

### Fixed

- None recoverable from the initial commit.

### Security

- No independent security evidence is attributed to this reconstructed entry.

### Performance

- No version-specific performance result is recoverable from the module history.

### Validation

- The initial source included a basic library test.

### Known limitations

- `0.2.0` and `0.3.0` have no verifiable version history in this repository;
  they are intentionally omitted.

#### Phase completion record

- Status: history reconstructed
- Recorded at: `2025-08-24T15:54:48+08:00` (source commit time)
- Source revision: `0322d269f0bef4953fd4d003f910b30e048c28ad`
- Commit range: initial commit only; no release tag found
- Validation summary: initial module test present
- Known limitations: registry publication and production behavior are unknown

## Version evidence

The version chain above is derived from `moon.mod` history. No Git tags were
present during reconstruction, and no `0.2.0` or `0.3.0` release evidence was
found. Do not use commit timestamps as publication dates.

Related governance pages:

- [Current validation facts](docs/release/current.md)
- [Release gates](docs/release/gates.md)
- [Distribution contents](docs/release/packaging.md)
- [Roadmap and phase records](docs/release/roadmap.zh-CN.md)
