# Current validation facts

> Status: local validation and explicitly labelled historical evidence; not production approval
> Scope: unreleased protocol suite, 0.7.0 alpha and historical release evidence
> Source: current working tree; exact revisions belong to local/CI evidence
> Last reviewed: 2026-11-23

Mooncakes published `0.7.0` on 2026-10-07. Its archive matches the frozen
distribution at `0967034` (SHA-256
`f7e3d2891f5e1ed943039f6438f396f77877c8d0045ef1fe5b06b068767477fa`).
[Hosted CI at that revision](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/37583031544)
passed the four target suites (455 Wasm, 324 Wasm-GC, 455 JS and 514 Native),
92 async integration tests and 131 Native TLS tests per OS on Linux, macOS and
Windows. These results describe the published alpha. The changes listed under
Unreleased in the changelog require their own validation.

## Typed HTTP/3 applications at `e5ca13e`

HTTP/3 now runs the same streaming request handler as HTTP/1 and HTTP/2.
The native client sends concurrent `Request[B]` values to one authenticated
HTTPS origin and returns `Response[BodyStream]` as soon as final headers arrive.
The client and server share body streaming and HTTP/2 and HTTP/3 share request
target and pseudo-field construction.

The native regressions exercise a stalled handler alongside a streaming echo,
handler failure, cancellation with only one permitted stream, a server returning
413 during upload, and a completed response read after the peer closes. They
check that the next request can acquire the released slot, that a stopped
producer is cancelled once, and that response bytes and trailers survive.

| Check | macOS arm64 | Ubuntu 24.04 arm64 VM |
| --- | --- | --- |
| Strict check, build and tests | Wasm 479/479, Wasm-GC 338/338, JS 479/479, Native 544/544 | Native 544/544 |
| Native QUIC, TLS, client and listener packages (included above) | 157/157 | 157/157 |
| Independent HTTP/1.1, HTTP/2 and h2c socket cases | 6/6 | 6/6 |
| Impaired HTTP/3 window with one fresh authenticated connection per request | 58 in 121.681 s | 59 in 120.950 s |

Both OSes used the pinned MoonBit compiler `0.10.14+7d59c7ec9` and aioquic
1.3.0. On each OS the independent client also completed 256 requests on one
MoonBit connection, eight concurrent requests on another, and a 4,096-byte echo
across the configured stream and connection flow-control windows. The relay
introduced loss, delay and reordering with MoonBit serving. In the reverse
direction, the MoonBit client verified a concurrent 4,096-byte echo and
131,072-byte download against aioquic on direct loopback.

Across the VM gateway three simultaneous Ubuntu aioquic clients each posted
32 requests to the typed macOS listener. All 96 responses had status 200 and
matched the connection's distinct 4,096-byte payload byte for byte. In the
reverse role the Ubuntu MoonBit client additionally verified both responses,
rejected a foreign request origin and rejected a mismatched certificate hostname.
The macOS peer logged both requests and a normal HTTP/3 close on the same connection.

The macOS package boundary check covered 28 manifests and 96 local dependencies.
The frozen 425-file source package passed a strict four-target check after
extraction. Its SHA-256 was
`d725113a3c87eacbcb1953066b6bb1e276bfd405bf6cff3f551f6955fe3e6788`.

The typed HTTP/3 client still takes a numeric endpoint and owns one connection
per scope. Origin pooling with DNS and server-initiated GOAWAY during shutdown
remain open. Both systems here share one physical Mac. Windows verification of
this revision, sustained capacity and recovery on independent hosts, and
independent security review remain release gates.

## HTTP/3 client and listener at `4355e04`

The portable `Http3Session` drives client and server streams, shares message
validation in both directions, and retains blocked writes within bounded
queues. The native client opens an authenticated connection to a numeric UDP
endpoint. The native server routes multiple peers through one UDP socket and
keeps accepted peers reachable during supervisor shutdown. Applications
consume per-stream events and can send body chunks and trailers.

The release checks below used MoonBit compiler `0.10.14+7d59c7ec9` and
aioquic 1.3.0. Both operating systems ran on one physical arm64 Mac.

| Check | macOS arm64 | Ubuntu arm64 VM |
| --- | --- | --- |
| Strict check, build and suite | Wasm 478/478, Wasm-GC 337/337, JS 478/478, Native 540/540 | Native 540/540 |
| Native QUIC, TLS, client and server packages | 154/154 | 154/154 |
| Independent HTTP/1.1, HTTP/2 and h2c socket cases | 6/6 | 6/6 |
| Impaired HTTP/3 window with a fresh authenticated connection per request | 147 connections in 300.440 s | 142 connections in 301.793 s |

With MoonBit serving, the independent client on each OS completed 256
requests on one connection, eight concurrent requests on another, and a
4,096-byte echo across both connection and stream flow-control windows. It
also exercised key update and rejected an untrusted CA. The UDP relay
introduced loss, delay and reordering in this direction. With aioquic
serving on direct loopback, the MoonBit client verified a concurrent 4,096-byte
echo and 131,072-byte download on one connection. The peer observed the
normal HTTP/3 close. A separate handshake with a mismatched hostname failed
before the application callback.

Across the VM gateway, three independent Ubuntu aioquic clients connected
concurrently to the same macOS listener. Each issued 32 POSTs over one
authenticated connection. All 96 returned the expected 4,096 bytes, with a
distinct payload digest per connection. In the reverse role, the Ubuntu
MoonBit client completed the same concurrent echo and download against the
macOS aioquic server and rejected the mismatched hostname.

The macOS async integration subset passed 96/96. All 33 native TLS tests
passed under AddressSanitizer on macOS with leak detection disabled. The
manifest and runtime restoration hashes matched. Package boundaries and the
generated public interfaces passed their checks. The frozen source package
contained 421 files, passed a strict four-target check after extraction, and
had SHA-256 `e633ea0c8cf6577cc2d898ca314f7a2b34f94f8171615779b9d650cc2e07d469`.

At this revision the native HTTP/3 client managed one connection per scope
and applications consumed raw stream events. The later typed application
API and its validation are recorded above.

## Streaming and field handling at `9a58bfe`

The HTTP/1 decoder now applies line limits to the unread line and accepts
a CRLF split at the exact limit. Both HTTP/2 and HTTP/3 use the same rules
for regular fields in requests, responses and trailers. Native TLS sends
`close_notify` when a server handler succeeds and bounds the final flush.
Authenticated HTTP/1.1 chunked and HTTP/1.0 close-delimited responses both
completed on real sockets. Abrupt TCP EOF still produced a receive error.
A custom body producer received its original collection failure once.
Before the repair the regression observed two cancellation callbacks.

The same paired Go workload used at `ffd5394` ran on the Ubuntu arm64
guest with the same compiler versions. Each protocol ran four ten-second
windows in Go, MoonBit, MoonBit, Go order. All completed with zero errors.
The probe checked status, protocol and all 65,536 response bytes on every
request. The ranges below span the two windows per server.

| Protocol and server | Successful requests | Requests/s | P95 (ms) |
| --- | ---: | ---: | ---: |
| HTTP/1.1 cleartext, MoonBit | 85,032 | 4,237–4,266 | 1.025–1.027 |
| HTTP/1.1 cleartext, Go | 337,581 | 16,724–17,034 | 0.471–0.482 |
| HTTP/2 with TLS 1.3, MoonBit | 61,605 | 3,077–3,083 | 1.846–1.852 |
| HTTP/2 with TLS 1.3, Go | 130,156 | 6,127–6,888 | 0.973–1.232 |

The previous MoonBit throughput ranges were 1,675–1,679 requests/s for
HTTP/1.1 and 1,110–1,221 requests/s for HTTP/2. The two revisions ran in
separate sessions. These loopback measurements include the client and server
on the same guest. CPU cost, RSS and independent-host capacity remain
unmeasured by this workload.

The strict macOS four-target check, build and tests passed (476 Wasm, 335
Wasm-GC, 476 JavaScript and 535 Native). Ubuntu arm64 passed its strict
Native check, build and all 535 tests. The six independent TCP cases passed
on each OS. All 33 macOS AddressSanitizer tests in the Native TLS package
passed. The manifest and runtime restoration hashes matched. This macOS
ASan run had leak detection disabled.

With aioquic 1.3.0 through the impaired UDP relay, both systems completed
256 requests on one authenticated connection, eight concurrent requests,
a 4,096-byte flow-controlled upload, a key update and wrong-CA rejection.
The independent 60-second loopback windows completed 30 fresh connections
in 60.626 seconds on macOS and 28 in 60.382 seconds on Linux.

The frozen package contained 412 files, passed the four-target check after
extraction, and had SHA-256
`126068c9fabd53863912c1a4d92aee291a50c629100c292ec9faecfe74e1bd2a`. The HTTP/3 application
client/server API, Windows verification at the candidate revision, sustained
independent-host capacity and final independent review remain open.

## Native HTTP servers at `ffd5394`

The native listener serves HTTP/1.1 and HTTP/2 over TLS. A one-second
preflight against the preceding revision `7dbae42` exposed a full HTTP/2
control queue during four concurrent 64 KiB POSTs. The probe completed 942
requests and recorded 164 errors. The server now coalesces receive-window
credits before the writer flushes them. The same preflight on the corrected
code completed 1,228 requests with zero errors.

The paired release-mode comparison used an Ubuntu 24.04 arm64 guest with four
vCPUs and 4 GiB of RAM, Go 1.26.8 and moonc 0.10.14+7d59c7ec9. The same
four-worker Go client sent 64 KiB POSTs over loopback, verified the protocol,
status and exact response body, and recorded zero errors in all eight measured
windows. Each protocol used two ten-second windows per server with a separate
one-second warmup. Ranges below span the two windows. P95 uses up to 100,000
samples per window.

| Protocol and server | Successful requests | Requests/s | P95 (ms) |
| --- | ---: | ---: | ---: |
| HTTP/1.1 cleartext, MoonBit | 33,544 | 1,675–1,679 | 2.453–2.464 |
| HTTP/1.1 cleartext, Go | 344,858 | 17,160–17,325 | 0.462–0.470 |
| HTTP/2 with TLS 1.3, MoonBit | 23,311 | 1,110–1,221 | 4.653–5.526 |
| HTTP/2 with TLS 1.3, Go | 140,787 | 7,004–7,074 | 0.940–0.951 |

This workload exposes a throughput and tail-latency gap. CPU and RSS were
not measured. See the [benchmark method](../development/performance.md#go-nethttp-external-reference)
for the workload and collection procedure.

Strict macOS checks, builds and tests passed for Wasm (473), Wasm-GC (334),
JS (473) and Native (532). The focused async and Native QUIC/TLS suites passed
95 and 140 tests respectively. Ubuntu passed the strict Native build and all
532 tests. Six independent HTTP/1.1, HTTP/2 and h2c socket exercises passed
on each OS. The macOS client again completed 32 cold-start requests against
two Linux nghttpd 1.59.0 origins, each advertising one stream slot. The 16
responses from each origin matched on one connection, including the TLS
origin with verified h2 ALPN. The host and guest share physical hardware.

The frozen distribution contained 409 files and passed a strict four-target
check after extraction. Its SHA-256 was
`43d3ec0fbf2b28fdd06f35df8d806272bb1306ffadb1f480a4e55778384529ba`.
Open release work includes the general HTTP/3 client/server API, Windows at
the candidate revision, independent-host soak and capacity measurements, and
final independent review.

## Origin-managed HTTP/2 at `4d3dab7`

The pinned toolchain passed the strict four-target build and tests on macOS
(470 Wasm, 332 Wasm-GC, 470 JS and 529 Native), plus 93 async integration
tests and 140 Native QUIC/TLS tests. Ubuntu 24.04 arm64 also passed the strict
Native build and all 529 tests. The six independent HTTP/1.1, HTTP/2 and h2c
socket exercises passed on both systems.

The native pool on macOS concurrently issued 32 requests from a cold start
to two Linux nghttpd 1.59.0 origins through the VM's TCP port forward. Each
origin advertised one concurrent stream. Each served 16 successful requests
on one connection. One origin used cleartext prior knowledge. The other used
the test certificate as a trust anchor and negotiated TLS with `h2` ALPN.
The client checked status 200 and exact body bytes for every response.

The distribution contained 406 files and passed a strict four-target check
after extraction. Its SHA-256 was
`4d694086b4f02888a650536b2c42ba102485edff149e8204c0d3f9c5f6a2f190`.
The host and VM share physical hardware.

## Unreleased protocol suite at `128f9fd`

The pinned toolchain built and tested the clean revision on macOS. Wasm passed
465 tests, Wasm-GC 332, JS 465 and Native 524. A separate Ubuntu 24.04 arm64
guest passed the strict Native check, build and all 524 tests.

| Exercise | Observed result |
| --- | --- |
| HTTP/1.1, HTTP/2 and h2c | Six independent real-socket cases passed on each OS. |
| MoonBit HTTP/2 client against Linux nghttpd 1.59.0 | The macOS client used one cleartext HTTP/2 connection through the VM's TCP port forward. With a peer limit of one stream, the warm-up and all 32 concurrently submitted GETs returned the expected status and body. |
| Linux aioquic 1.3.0 against the macOS HTTP/3 server | All 32 POST requests shared one authenticated QUIC connection through a UDP relay on the VM gateway. Each 4096-byte echo matched the input SHA-256. |
| Impaired HTTP/3 loopback | Each OS completed a separate 256-request connection, an eight-request concurrent batch, a flow-controlled 4096-byte echo, a key update and wrong-CA rejection. The duration window completed 45 fresh connections in 91.848 seconds on macOS and 30 in 60.413 seconds on Linux. |
| Distribution | The frozen archive contained 401 files and passed a strict four-target check after extraction. SHA-256 was `e71923d13bca673acd7c25fe51cb4e0567320f5ff6ff68e9ddd03835d4a0c701`. |

These HTTP/3 runs used a host and guest on one physical machine.

## Earlier evidence

The earlier local security remediation and final validation are recorded in the
[2026-10-06 remediation index](../development/security-remediation-2026-10-06.md).
Clean revision `201e7ae` passed hosted CI run `37516695805`: Wasm 455/455,
Wasm-GC 324/324, JavaScript 455/455 and Native 514/514; async integration
passed 92/92 and Native TLS passed 131/131 on Ubuntu, macOS and Windows. The
run also passed interoperability, frozen package evidence and ephemeral
coverage generation. All 25 finding-index roots have local repairs and
regressions; scan coverage and production approval remain separate open gates.
The following table retains the earlier 2026-10-03 validation snapshot. Its
local and hosted results apply to their original source state; they are not
fresh cross-platform or interoperability evidence for the changed working tree.

| Suite | Result |
| --- | ---: |
| Wasm | 395/395 |
| Wasm-GC | 297/297 |
| JavaScript | 395/395 |
| Native | 450/450 |
| Async integration (historical) | 55/55 |
| Native TLS revocation regression (2026-10-03) | 31/31 |
| Native TLS AddressSanitizer (earlier macOS run) | 31/31; runtime and manifest restoration hashes match; leak detection unavailable |
| Native TLS identity suite, Ubuntu/macOS/Windows (historical hosted run) | 97/97 per OS |
| Real-socket HTTP/1.1, HTTP/2 and h2c (2026-10-03) | 6 cases passed |
| Independent HTTP/3 / QUIC TLS (historical) | GET, POST, key update, wrong-CA rejection; 8 concurrent streams passed |

Three impaired HTTP/3 / QUIC-TLS loopback windows were requested for 3600
seconds with eight concurrent requests. Each completed its requested window
and recorded loss, delay, reordering, recovery and certificate-negative cases.
The evidence was produced from a dirty local worktree, so it is bounded
loopback evidence rather than a clean cross-host or public-network release
claim. The repository's QUIC Retry, version negotiation, loss recovery and
stream state tests also passed in the four-target and Native suites.

Native TLS identity tests passed on all three operating systems, including
hostname, trust, expiry, SAN/wildcard, chain, mTLS, ALPN and credential-negative
cases. The independent HTTP/3 run also confirmed wrong-CA rejection.

The `0.7.0` archive excludes Native TLS testdata, including private keys and
certificate fixtures. A clean-tree package check records its exact file list,
sizes and SHA-256 in local or CI release evidence. Those generated files are
deliberately outside Git and the published archive; keeping the hash outside
the archive avoids a self-referential digest.
Resolved dependency versions are captured in that release evidence;
Moon does not provide a committed lockfile for this module.

The 2026-10-07 publication attempt exposed a gap in the earlier archive checks:
the TLS white-box tests imported a helper from excluded `repo-tools` sources.
The helper now lives in the included `internal/test_support` tree and remains
a test-only dependency. The distribution gate now checks all four targets from
an isolated extraction. Earlier inventory and Git-blob checks did not exercise
that step and must not be read as successful extracted-package validation.

The controlled method-v3 Native release HTTP/1 decoder comparison recorded a
passing local window:
median regression was -60.91% and geometric-mean regression was -61.01%, with
all six paired ratios and relative-noise checks within threshold. The earlier
`71512.a31c8121` window remains retained as `inconclusive-noisy`. The second
window was collected after that result, contrary to the method's no-retry rule;
it is supplementary evidence and does not supersede the inconclusive gate.
Neither result supports an HTTP/2, HTTP/3, TLS, QUIC, socket-capacity or
cross-platform performance claim. The later socket method-v6 result below is
the current scoped socket gate evidence.

The separately declared socket method-v2, method-v4 and method-v5 comparisons
remain immutable `inconclusive-noisy` evidence. Their raw windows were kept and
were not retried or reinterpreted. Method-v6 then used the documented 20-second
phase duration and retained all six AB/BA pairs in
local/CI evidence for the source revision.
All eight metrics passed: maximum relative noise was 4.62%, maximum pair cost
was 10.08% for HTTP/1 throughput, and every median/geomean cost stayed within
the 15%/20% limits. This closes only the declared local Native socket workload;
it is not a production-wide or cross-platform performance claim.

The Go `net/http` H1/H2 runner measured the Go baseline in the hosted release
run. The unreleased comparison at `ffd5394` above adds both servers on one guest.

The historical 2026-10-03 Standard security review is sealed under scan
`5e0f9eab-60e1-458a-b97a-e89b3a69aa48` with zero reportable findings and
partial coverage. It re-traced the six remediated protocol findings, the
standalone distribution checker and Native TLS credential parsing. External
dependencies, cross-platform archive metadata, public network and host
deployment remain outside its evidence. The final working-tree diff scan
`886a88d1-5078-4e4d-a1ea-3e0b96c1e822` also reports zero findings for the
changed TLS credential parser and distribution manifest, with the same local
scope limitations.

The subsequent two Deep Scans ended with 429/403 failures and partial coverage,
retaining 58 overlapping finding records against the same dirty snapshot.
The earlier zero-finding results are historical evidence. The
[2026-10-06 remediation index](../development/security-remediation-2026-10-06.md)
tracks all 25 distinct repair boundaries and their local verification. The
security gate still requires adequate coverage at the release revision; a new
complete scan or production security approval is not claimed.

The independent security-boundary review of commit
`391e415e5ce2bff3e4abc52d5c5cca80d9f60b1a` is sealed under scan
`d57f88d0-f034-4348-a694-8c7944a30d08`. It reported five medium findings and
one low finding: three HTTP/2 lifecycle/flow-control issues, QUIC CID history
growth, quadratic QPACK instruction processing, and multicast UDP source
misattribution. The report and coverage remain in the local security evidence
directory. This review covered the principal security boundaries, with partial
repository coverage; it is not an all-files
or dependency-vulnerability clean bill. Remediation validation is tracked
separately from the immutable report.

The continuation repairs the six reported controls and also exercises consumer
cancellation after END_STREAM, cancellation of suspended uploads, server early
responses after request-body cancellation, delayed Handshake packets with pending
CID retirements, and packet-space budgeting for retirement frames. Receive credit
is claimed only after the write lock is held, and is retired exactly once on
discard, so cancellation cannot lose a peer-visible flow-control update.
`BodyStream` now has a separate optional `on_cancel` callback; cancelling after
producer termination clears buffered frames while preserving the first terminal
cause and the once-only `on_terminate` contract. QUIC's driver still issues only
its initial local CID; this limitation is documented in
[`CID-SUPPORT.md`](../../protocol/quic/CID-SUPPORT.md).

Strict formatting, architecture, four-target check/build/test, generated
interfaces, distribution allowlist and six independent TCP interoperability
cases are recorded in local/CI evidence for their source revision. These raw
logs remain ephemeral and are not required to read this document.

Native OpenSSL CRL and stapled OCSP checks passed fresh, stale, future,
revoked, unknown, malformed and missing-staple cases with fail-closed behavior.
The implementation intentionally does not fetch OCSP responses online, and
Wasm requires a host-provided TLS/revocation capability. Historical security
reviews have the scoped limitations above. The open production gates include release-revision security coverage and
independent-host interoperability.

See [release gates](gates.md) for the remaining acceptance criteria and the
[GitHub Actions run](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/36837820455)
for the historical hosted log. Raw CI files from that run are not a current
package dependency or a release upload claim.
