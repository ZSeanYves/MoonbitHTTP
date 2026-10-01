# v1 validation and release evidence

> Status: historical
> Scope: validation guide and development measurements for the 2026-09-30 worktree
> Original path: `docs/v1-testing.md`
> Archived from Git revision: `ee8496d365cf7f5aada0a4cf2cdf7a1b96b5391e`
> Archived: 2026-10-01. The original record below is retained as historical evidence;
> its commands, paths and references to current state apply to its original context.
> Use the [maintained testing guide](../../development/testing.md),
> [current evidence](../../release/current.md) and [release gates](../../release/gates.md).

Run Moon commands serially. The compiler, test runner, benchmark runner and
interface generator share the module build directory. A green unit-test
matrix establishes behavior on those targets; it does not establish external
interoperability, certificate validation, sustained load or performance.

## Regression layers

| Layer | Location | Evidence |
| --- | --- | --- |
| Incremental codecs | `http1`, `http2`, `quic`, `http3` tests | Split boundaries, malformed bytes, bounded buffers and wire encodings |
| State transitions | Protocol state tests | Legal frames per phase, flow control, path validation, cancellation and terminal states |
| Drivers | `service`, QUIC driver tests | Reader/Writer integration, multiplexing, backpressure and endpoint actions |
| Independent sockets | `tools/interoperability.mbtx` | curl and wget HTTP/1.1 GET/POST, nghttp HTTP/2 prior knowledge and h2c upgrade |

New HTTP/2 regressions verify that peer `SETTINGS_HEADER_TABLE_SIZE` changes
the outgoing HPACK encoder, without clearing the independent receiving
context. Consecutive size changes emit the smallest value and final value
before the next header block. Client and server tests decode the actual
outgoing HEADERS payload under a zero-size peer limit. QUIC state regressions
cover illegal handshake frames and two-driver candidate-path challenge and
response, including rejection of candidate application data before validation.
The shared `codec` Huffman tests retain the RFC 7541 vector and cover all 256
octet values, long codes following partial bytes, explicit EOS and invalid
padding. HPACK and QPACK import that primitive directly; HTTP/3 no longer
depends on the HTTP/2 package for compression primitives.

## Local checks

```text
moon fmt --check
moon run tools/check_architecture.mbtx
moon check --target all --deny-warn --warn-list +73
moon build --target all --deny-warn --warn-list +73
moon test --target all --no-parallelize --deny-warn --warn-list +73
moon info --target all
moon run tools/interoperability.mbtx
moon run tools/prepare_http3_interop.mbtx
moon run tools/http3_interoperability.mbtx --impair --concurrent-requests 8 --duration-seconds 300
moon run tools/benchmarks.mbtx
moon coverage clean
moon coverage analyze -- -f cobertura -o coverage.xml
```

## Latest measured development run (2026-09-30)

The current dirty worktree is based on Git revision
`77024d99398981806b9ca57fc374fd96832eec59`. After the final recovery, PTO,
Retry token, and key-update edits, the strict four-target matrix passed with Wasm
`361/361`, Wasm-GC `281/281`, JS `361/361`, and Native `403/403`.
`moon check --target all` and `moon build --target all` also passed with
warnings denied. The focused suites passed QUIC `77/77` and Native TLS
`20/20`. The final formatting check, architecture check (`25` manifests and
`67` local dependency edges), `moon info --target all` and `git diff --check`
also passed. `moon info` reports expected Native-only interface
differences for adapter and command packages; those packages have no
canonical Wasm interface.

The CI workflow pins MoonBit `0.10.14+7d59c7ec9`, runs the full target matrix
with `--no-parallelize`, regenerates and checks every `pkg.generated.mbti`, and
keeps Codecov upload failures non-blocking because forked pull requests do not
receive repository secrets. The Native TLS matrix runs the QUIC and TLS native
tests on Ubuntu, macOS and Windows with an explicit OpenSSL runtime check;
Ubuntu uses the checksum-pinned 3.5.8 build, while macOS and Windows verify the
selected host installation. Validation artifacts include coverage, package and
interoperability evidence.

The independent socket evidence is stored at
`_build/evidence/interoperability/moonbithttp-interop.24727.514ef45f/` and
contains six passing HTTP/1.1, HTTP/2 prior-knowledge, and h2c cases. The
independent aioquic evidence is stored at
`_build/evidence/http3-interoperability/moonbithttp-h3-interop.32677.d8f2a82a/`:
GET, POST, client key update, wrong-CA rejection, 8 concurrent authenticated
requests on one aioquic connection, and 14 repeated authenticated requests
over a requested 30-second window passed against the pinned aioquic `1.3.0`
example. The positive cases used real loopback UDP sockets and a deterministic
loss/reorder proxy: 18 isolated proxy sessions received 1,259 datagrams,
forwarded 1,162, dropped 36 Initial, 18 Handshake and 43 Application datagrams,
delayed 582 datagrams and observed 255 actual reorderings. Both directions
were exercised and every delay queue was empty at shutdown. The largest
observed forwarding delay was 26 ms for the nominal 20 ms profile.

After the PTO bookkeeping fix, the final-source impaired run passed at
`_build/evidence/http3-interoperability/moonbithttp-h3-interop.60702.4086ee70/`
using the newly built server binary. GET, POST, key update, wrong-CA and the
eight-stream concurrent batch completed through Initial/Handshake/Application
loss, delay and reorder events, with empty proxy queues at shutdown. The earlier
30-second repeated-connection window remains evidence for the earlier snapshot
only.

The proxy parses public QUIC long-header lengths to find coalesced Handshake
packets, preserves encrypted payload bytes, and uses a distinct upstream UDP
socket for each aioquic invocation. It drops the first Initial in each
direction, the first server Handshake, and every eleventh Application
datagram; it delays every second remaining datagram by four 5 ms timer ticks.
Each impaired session must observe both Initial loss and server Handshake
loss plus real reordering in both directions. A timer flush prevents a lone
delayed handshake packet from waiting indefinitely. Packet counters, event
order, endpoints, qlog, commands, process exits, versions and binary digests
are saved with the case; child tasks are cancelled and joined before sockets
close. Client commands have a 30-second deadline and preserve output even on
timeout. `--duration-seconds 300` requests a five-minute repeated-connection
window; `--concurrent-requests 8` adds one eight-stream concurrent batch.
These are bounded loopback interoperability checks, not a multi-hour WAN or
capacity claim. CI runs a 60-second impaired window and the concurrent batch.

The QUIC driver suite contains deterministic loss/reordering, PTO
retransmission, Retry integrity and CRYPTO replay, Version Negotiation CID
gates, exact delivery of all concurrent streams, and path validation tests.
The final matrix covers these recovery and Retry changes. The Native TLS
suite passed `20/20`, including SAN/CN
precedence, wrong IP, IPv6, expiry/not-yet-valid, EKU, full and missing
intermediate chains, whole-label and partial-label wildcard behavior, mTLS,
ALPN/version and malformed-credential negatives. CI schedules
that suite on Linux, macOS and Windows using paired OpenSSL 3 libraries;
Windows and Linux hosted-runner evidence remains an external CI artifact.

The final work addresses three bounded QUIC gaps. Recovery now distinguishes
peer address validation from local amplification exemption, applies ACK delay
according to handshake confirmation, and retains one congestion-loss epoch
across packet-number spaces. PTO keeps the source packet in recovery while a
probe uses a new packet number, so original and probe ACKs release separate
bytes-in-flight entries. Retry uses a bounded token manager and validated
context; the real Native TLS test deliberately drops the first post-Retry
Initial and completes through `QuicTlsDriver::poll`. AEAD limits are counted
per packet space, with typed failure handling and five new boundary tests.
The concurrent-stream regression requires exact delivery of all 16 streams
after deliberate loss and reordering. These tests do not establish complete
RFC 9002 recovery conformance or production capacity.

The shared codec buffer now consumes with a cursor and amortized compaction,
so HTTP/2 and HTTP/3 frame batches do not repeatedly copy their unread suffix.
Native policy-denied peers are discarded without consuming the supervisor's
fatal accept-error budget. HTTP/3 frame headers are inspected in place and
only the current frame is copied, avoiding quadratic unread-suffix rebuilds.

The bounded local stress evidence is
`_build/evidence/stress/moonbithttp-stress.5996.5e4736e1/result.json` (300
seconds, 58,149 HTTP/1 requests, 58,191 HTTP/2 streams, 1,872 deliberate
cancellations, 0 failures, and 7,624,458,240 verified response bytes). It is
useful lifecycle evidence, while a production capacity threshold is still
unassigned. The latest benchmark evidence is
`_build/evidence/benchmarks/moonbithttp-bench.6594.43e0b868/`; it executed the
HTTP/1 decoder and shared Huffman benchmarks but intentionally has no accepted
performance gate. The current coverage run produced `coverage.xml` with 7,357
of 10,597 lines covered (`69.4253%`). The current macOS clang AddressSanitizer
run passed all `20/20` Native TLS tests and restored the package/runtime input
hashes; macOS leak detection is unavailable because the system runtime does not
provide LeakSanitizer.

The interoperability tool requires `curl`, `wget` and `nghttp` and fails if
any is unavailable. It builds the Native smoke server, rejects a pre-existing
listener on `127.0.0.1:18080`, starts its own child process, bounds readiness
and client execution, and cancels/reaps the server on completion or failure.
Each case checks its body and protocol/status evidence. Logs are stored under
`_build/evidence/interoperability/` in a unique directory. The result records
the Git revision, dirty flag, server binary hash and whether the tool built
the server. `--server PATH` supports an already built executable; the report
labels this as caller-supplied and cannot establish that binary's source.

The controlled comparison is `tools/performance_comparison.mbtx`. Method v2
freezes HEAD `77024d99398981806b9ca57fc374fd96832eec59`, checks full source
manifests and identical benchmark bytes, then runs six interleaved AB/BA
native release pairs. Each arm retains eight raw 100,000-operation HTTP/1
decoder timings after a fixed 10,000-operation warmup. The acceptance result
at `_build/evidence/performance/moonbithttp-performance.32792.d5104d08/result.json`
is `pass-threshold`: current median regression `+0.2914%`, paired geometric
mean `-0.4660%`, largest pair regression `+2.3441%`, and largest relative
standard deviation `8.2981%`. The predeclared ceilings remain 15% for the
median, 20% for each pair and geometric mean, and 10% for noise. All 96 raw
timings are retained with no trimming or retry. This closes the gate for one
local HTTP/1 codec workload only; it does not measure HTTP/2, HTTP/3, TLS,
QUIC, sockets or cross-platform performance. The prior method-v1 result at
`moonbithttp-performance.19299.a1890263` remains `inconclusive-noisy` and is
retained separately; see the archived [performance methodology](performance-v1.md).

Coverage behavior was verified with the installed CLI's help: `analyze` runs
instrumented tests; `report` consumes artifacts. Cleaning before analysis
prevents prior runs from contaminating the new report. Coverage is not an
interoperability or security claim.

`tools/check_architecture.mbtx` reads all local package manifests, distinguishes
main/test/wbtest imports, and checks the permitted dependencies of core and
optional policy packages. It rejects reintroduced `io` facades, HTTP/3 imports
of HTTP/2 and portable packages importing Native adapters. It compares the
actual graph against `docs/v1-dependencies.md`; after an intentional manifest
change, regenerate that document with `--write` and review the resulting diff.

## Packaging

```text
moon run tools/release_evidence.mbtx --check-clean
moon run tools/release_evidence.mbtx
```

The first command only checks Git cleanliness. The second requires a clean
worktree, invokes `moon package --frozen --list`, rejects duplicate, unsafe,
generated or untracked archive entries, compares every member's bytes with
the frozen Git revision, then checks cleanliness and revision again. It saves
the archive digest, sizes, per-file digests, exact `moon.mod`, toolchain and
resolved dependency graph under `_build/evidence/release/<revision>/`.
Neither command commits, publishes or approves production release.

The module pins dependency versions in `moon.mod`. This repository has no
committed resolver lockfile; `.mooncakes/.moon-lock` is a process lock, not a
dependency lock. The resolved dependency snapshot is explicitly labeled as
evidence, and must not be described as lockfile enforcement. The live Moon
toolchain deprecates `options(exclude: ...)`; this change adds neither that
deprecated setting nor a `.moonignore`. Archive provenance is checked against
Git directly. The current dirty development tree is ineligible for release.

## Open production gates

- Multi-hour external QUIC/TLS pressure remains open. The bounded real-socket
  HTTP/3 window now injects loss and reordering, while its loopback route,
  deterministic profile and short duration do not prove hostile WAN behavior
  or production capacity.
- Hosted Linux/macOS/Windows Native TLS matrix completion remains CI evidence;
  the local macOS run proves 20/20 and paired OpenSSL loading, not every host.
- Certificate revocation controls and CRL/OCSP negative tests remain outside
  the current Native TLS API and are an explicit capability gap.
- Performance thresholds for HTTP/2, HTTP/3, TLS/QUIC and real socket capacity
  remain unassigned; the accepted method-v2 result covers only the stated
  local HTTP/1 decoder workload.
- The current Codex Security report is source-snapshot scoped and partial; it
  excludes uncommitted edits made after snapshot capture and dynamic runtime
  attack testing. A new final-source scan remains required.
- A package produced by the current Moon toolchain. `moon package --list`
  currently accepts `0.7.0`; final packaging still requires a clean reviewed
  revision and regenerated release evidence. Packaging was not repeated after
  the final edits; the existing archive and digest do not cover them.

CI installs mandatory socket clients and the OpenSSL runtime, runs the tools,
and uploads their evidence even when a step fails. Missing artifacts or
skipped capabilities remain visible; no general production-ready conclusion
is derived from the HTTP/1.1 and HTTP/2 smoke checks.
