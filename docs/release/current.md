# Current validation facts

> Status: current hosted evidence; not production approval
> Scope: MoonbitHTTP 0.7.0 dependency refresh and package migration
> Source: GitHub Actions run 36837820455 at revision `01a8f2cbcbac238642fe7fdf78ec000f2f881ee7`
> Last reviewed: 2026-10-01

The hosted workflow passed on the exact revision above. It refreshed package
registry metadata, checked formatting and architecture boundaries, checked and
built every configured target, regenerated public interfaces, ran the test
matrix and interop suites, executed benchmarks, verified the frozen package,
and uploaded validation evidence.

| Suite | Result |
| --- | ---: |
| Wasm | 361/361 |
| Wasm-GC | 281/281 |
| JavaScript | 361/361 |
| Native | 403/403 |
| Async integration | 55/55 |
| Native TLS, Ubuntu | 97/97 |
| Native TLS, macOS | 97/97 |
| Native TLS, Windows | 97/97 |
| Real-socket HTTP/1.1, HTTP/2 and h2c | 6 cases passed |
| Independent HTTP/3 / QUIC TLS | GET, POST, key update, wrong-CA rejection; 8 concurrent streams passed |

The impaired HTTP/3 run lasted 60 seconds and completed 30 repeated requests;
the deterministic UDP proxy recorded packet loss, delay and reordering. This
is a bounded interoperability window, not the outstanding multi-hour pressure
run. The repository's QUIC Retry, version negotiation, loss recovery and stream
state tests also passed in the four-target and native TLS suites.

Native TLS identity tests passed on all three operating systems, including
hostname, trust, expiry, SAN/wildcard, chain, mTLS, ALPN and credential-negative
cases. The independent HTTP/3 run also confirmed wrong-CA rejection.

The frozen `0.7.0` development package contains 383 files (555,024 compressed
bytes; 1,813,851 unpacked bytes) and has SHA-256
`1c1ea2862ba862d45afb674931a50c98ef1baeed5b6730e714a76037c0e1892c`.
Resolved dependency versions are captured in the uploaded release evidence;
Moon does not provide a committed lockfile for this module.

Native release benchmarks executed and their raw output was archived. A
performance threshold and controlled old/new comparison are still open, as are
multi-hour external QUIC/TLS pressure and the final security review. Passing
this workflow does not approve a production release or publish the package.

See [release gates](gates.md) for the remaining acceptance criteria and the
[GitHub Actions run](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/36837820455)
for the complete hosted log and downloadable evidence.
