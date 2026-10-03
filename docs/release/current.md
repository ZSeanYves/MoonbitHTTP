# Current validation facts

> Status: current hosted evidence; not production approval
> Scope: MoonbitHTTP 0.7.0 dependency refresh and package migration
> Source: current local validation revision (see Git revision in the release artifact)
> Last reviewed: 2026-10-03

The current working tree passed the four-target checks and regression matrix.
The older hosted run remains the source for the cross-platform Native TLS
identity suite; the current revocation tests are a separate Native run. This
page records the current local evidence and keeps the older hosted facts from
being mistaken for evidence for this revision.

| Suite | Result |
| --- | ---: |
| Wasm | 373/373 |
| Wasm-GC | 286/286 |
| JavaScript | 373/373 |
| Native | 426/426 |
| Async integration | 55/55 |
| Native TLS revocation regression (current) | 31/31 |
| Native TLS identity suite, Ubuntu/macOS/Windows (historical hosted run) | 97/97 per OS |
| Real-socket HTTP/1.1, HTTP/2 and h2c | 6 cases passed |
| Independent HTTP/3 / QUIC TLS | GET, POST, key update, wrong-CA rejection; 8 concurrent streams passed |

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

The frozen `0.7.0` development package contains 364 files (558,343 compressed
bytes; 1,858,298 unpacked bytes) and has SHA-256
`ae2d4834d47077267219b5408abaee29133881d3cd6d6baa9e0986ec58fe11ba`.
Native TLS private keys and certificate fixtures are excluded from the package;
only their test-data README is included.
Resolved dependency versions are captured in the uploaded release evidence;
Moon does not provide a committed lockfile for this module.

The controlled method-v3 Native release HTTP/1 decoder comparison passed in
`_build/evidence/performance/moonbithttp-performance.73465.b03a10e5`:
median regression was -60.91% and geometric-mean regression was -61.01%, with
all six paired ratios and relative-noise checks within threshold. The earlier
`71512.a31c8121` window remains retained as `inconclusive-noisy`; neither result
supports an HTTP/2, HTTP/3, TLS, QUIC, socket-capacity or cross-platform
performance claim.

Native OpenSSL CRL and stapled OCSP checks passed fresh, stale, future,
revoked, unknown, malformed and missing-staple cases with fail-closed behavior.
The implementation intentionally does not fetch OCSP responses online, and
Wasm requires a host-provided TLS/revocation capability. The final security
review is still open, so this evidence does not approve production release or
publish the package.

See [release gates](gates.md) for the remaining acceptance criteria and the
[GitHub Actions run](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/36837820455)
for the complete hosted log and downloadable evidence.
