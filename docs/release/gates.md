# Release gates

> Status: canonical
> Scope: production approval for the 0.7.0 line
> Source: current working tree; exact revisions belong to local/CI evidence
> Last reviewed: 2026-10-07

The current hosted run validates the physical package migration and dependency
refresh. Production approval remains open until every remaining gate below is
closed with evidence at the release revision.

| Gate | State | Required evidence |
| --- | --- | --- |
| Four target regression matrix | passed on clean revision `201e7ae` and hosted CI `37516695805` | Wasm 455/455, Wasm-GC 324/324, JS 455/455, Native 514/514; see [2026-10-06 remediation evidence](../development/security-remediation-2026-10-06.md) |
| Native TLS identity and negative suites | passed on clean hosted revision | Native TLS suite passed 131/131 on Ubuntu, macOS and Windows; the earlier 97-test-per-OS identity run remains historical evidence |
| HTTP/1, HTTP/2 and HTTP/3 interoperability | bounded runs passed | Real-socket H1/H2/h2c cases and three independent impaired H3/QUIC-TLS loopback windows; public cross-host behavior is not implied |
| QUIC Retry, version negotiation, loss recovery, stream concurrency | regression and bounded pressure evidence passed | Protocol tests plus 8 concurrent H3 requests; the long runs use a loopback peer and controlled impairment |
| Certificate identity and negative suites | configured suites passed on all three OSes | Hostname, expiry, chain, trust, wildcard, mTLS and wrong-CA rejection cases |
| Performance threshold and controlled old/new comparison | passed for the scoped socket workload | Method-v6 local/CI evidence contains six AB/BA pairs for independent 20-second HTTP/1, HTTP/2 and cancellation phases; all 8 metrics passed behavior, regression and 10% noise checks. Scope remains local Native loopback only |
| Go `net/http` H1/H2 external reference | not run in this environment | The standard-library fixture and runner are present; `go` is unavailable locally, so no Go comparison is claimed. When available, use the same payload, concurrency, duration and AB/BA order; this is an external reference, not a threshold |
| Long-duration QUIC/TLS interoperability | historical loopback evidence passed; public cross-host evidence absent | Three requested 3600-second impaired aioquic windows passed with 8 concurrent requests; evidence came from a dirty loopback worktree; the redundant hosted loopback job was removed at the user's request |
| Final security scan and review | known finding-index roots locally remediated; complete release-revision coverage still open | The two failed Deep Scans retained 58 overlapping records covering 25 repaired roots. Focused regressions, four-target checks and bounded H3 loopback validation passed; the three candidate-review paths were reproduced, repaired and covered by focused tests. See the [remediation index](../development/security-remediation-2026-10-06.md). The scans remain partial and earlier zero-finding scans do not close this gate for the changed tree |
| CRL/OCSP or documented deployment limitation | passed with scoped limitation | Native OpenSSL offline CRL and stapled OCSP checks cover freshness, identity, revocation and malformed inputs; online OCSP fetching and Wasm host providers are out of scope |
| Clean package and publication decision | historical inventory checks passed; isolated extraction is now required | Revision `201e7ae` passed the distribution allowlist and Git-blob checks, but those checks missed an excluded white-box test import found on 2026-10-07. The gate now also runs all-target `moon check` on a fresh extraction. A release tag, registry publication decision and final security approval remain separate |

The latest passing facts are recorded in [Current validation facts](current.md).
Historical reports in [the archive](../archive/2026-09/) are evidence for their
original revisions and do not close a current gate.
