# Current validation facts

> Status: local validation and explicitly labelled historical evidence; not production approval
> Scope: MoonbitHTTP 0.7.0 security remediation and historical release evidence
> Source: current working tree; exact revisions belong to local/CI evidence
> Last reviewed: 2026-10-07

The latest local security remediation and final validation are recorded in the
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

The separate Go `net/http` H1/H2 reference runner is implemented, but its
baseline and MoonBitHTTP comparison are `not_run` in this environment because
the `go` executable is unavailable. A future run must measure both H1 and H2
with the same workload and record a compact summary; Go is an external
reference, not a release threshold.

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
reviews have the scoped limitations above. The incomplete final security
coverage, unmeasured Go H1/H2 comparison, and absence of a release tag or
publication record still prevent production approval or publication.

See [release gates](gates.md) for the remaining acceptance criteria and the
[GitHub Actions run](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/36837820455)
for the historical hosted log. Raw CI files from that run are not a current
package dependency or a release upload claim.
