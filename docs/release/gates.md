# Release gates

> Status: canonical
> Scope: production approval for the 0.7.0 line
> Source: current local validation revision (see Git revision in the release artifact)
> Last reviewed: 2026-10-03

The current hosted run validates the physical package migration and dependency
refresh. Production approval remains open until every remaining gate below is
closed with evidence at the release revision.

| Gate | State | Required evidence |
| --- | --- | --- |
| Four target regression matrix | passed on current validation revision | Wasm 373/373, Wasm-GC 286/286, JS 373/373, Native 426/426; see [current evidence](current.md) |
| Native TLS identity and negative suites | prior hosted cross-platform suite passed; current revocation suite passed on Native | The hosted 97-test-per-OS identity suite remains historical evidence; current Native revocation tests are 31/31 |
| HTTP/1, HTTP/2 and HTTP/3 interoperability | bounded runs passed | Real-socket H1/H2/h2c cases and three independent impaired H3/QUIC-TLS loopback windows; public cross-host behavior is not implied |
| QUIC Retry, version negotiation, loss recovery, stream concurrency | regression and bounded pressure evidence passed | Protocol tests plus 8 concurrent H3 requests; the long runs use a loopback peer and controlled impairment |
| Certificate identity and negative suites | configured suites passed on all three OSes | Hostname, expiry, chain, trust, wildcard, mTLS and wrong-CA rejection cases |
| Performance threshold and controlled old/new comparison | passed for the declared workload | Current method-v3 window `moonbithttp-performance.73465.b03a10e5` passed; the separate noisy window remains retained; scope is Native release HTTP/1 decoder only |
| Long-duration QUIC/TLS interoperability | bounded loopback evidence passed; public peer out of scope | Three requested 3600-second impaired aioquic windows passed with 8 concurrent requests; evidence came from a dirty loopback worktree |
| Final security scan and review | open | Post-change scan artifact and disposition of findings |
| CRL/OCSP or documented deployment limitation | passed with scoped limitation | Native OpenSSL offline CRL and stapled OCSP checks cover freshness, identity, revocation and malformed inputs; online OCSP fetching and Wasm host providers are out of scope |
| Clean package and publication decision | package verified; publication pending final security gate | 364 files, 558,343 bytes compressed, 1,858,298 bytes unpacked; SHA-256 is recorded in [current evidence](current.md) |

The latest passing facts are recorded in [Current validation facts](current.md).
Historical reports in [the archive](../archive/2026-09/) are evidence for their
original revisions and do not close a current gate.
