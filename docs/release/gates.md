# Release gates

> Status: canonical
> Scope: production approval for the 0.7.0 line
> Source: current working tree; exact revisions belong to local/CI evidence
> Last reviewed: 2026-10-06

The current hosted run validates the physical package migration and dependency
refresh. Production approval remains open until every remaining gate below is
closed with evidence at the release revision.

| Gate | State | Required evidence |
| --- | --- | --- |
| Four target regression matrix | passed on the current local dirty working tree | Wasm 452/452, Wasm-GC 323/323, JS 452/452, Native 511/511; see [2026-10-06 remediation evidence](../development/security-remediation-2026-10-06.md) |
| Native TLS identity and negative suites | prior hosted cross-platform suite passed; current revocation suite passed on Native | The hosted 97-test-per-OS identity suite remains historical evidence; current Native revocation tests are 31/31 |
| HTTP/1, HTTP/2 and HTTP/3 interoperability | bounded runs passed | Real-socket H1/H2/h2c cases and three independent impaired H3/QUIC-TLS loopback windows; public cross-host behavior is not implied |
| QUIC Retry, version negotiation, loss recovery, stream concurrency | regression and bounded pressure evidence passed | Protocol tests plus 8 concurrent H3 requests; the long runs use a loopback peer and controlled impairment |
| Certificate identity and negative suites | configured suites passed on all three OSes | Hostname, expiry, chain, trust, wildcard, mTLS and wrong-CA rejection cases |
| Performance threshold and controlled old/new comparison | passed for the scoped socket workload | Method-v6 local/CI evidence contains six AB/BA pairs for independent 20-second HTTP/1, HTTP/2 and cancellation phases; all 8 metrics passed behavior, regression and 10% noise checks. Scope remains local Native loopback only |
| Go `net/http` H1/H2 external reference | not run in this environment | The standard-library fixture and runner are present; `go` is unavailable locally, so no Go comparison is claimed. When available, use the same payload, concurrency, duration and AB/BA order; this is an external reference, not a threshold |
| Long-duration QUIC/TLS interoperability | historical loopback evidence passed; public cross-host evidence absent | Three requested 3600-second impaired aioquic windows passed with 8 concurrent requests; evidence came from a dirty loopback worktree; the redundant hosted loopback job was removed at the user's request |
| Final security scan and review | known finding-index roots locally remediated; complete release-revision coverage still open | The two failed Deep Scans retained 58 overlapping records covering 25 repaired roots. Focused regressions, four-target checks and bounded H3 loopback validation passed; the three candidate-review paths were reproduced, repaired and covered by focused tests. See the [remediation index](../development/security-remediation-2026-10-06.md). The scans remain partial and earlier zero-finding scans do not close this gate for the changed tree |
| CRL/OCSP or documented deployment limitation | passed with scoped limitation | Native OpenSSL offline CRL and stapled OCSP checks cover freshness, identity, revocation and malformed inputs; online OCSP fetching and Wasm host providers are out of scope |
| Clean package and publication decision | requires a fresh clean-revision artifact | Run the distribution allowlist and Git-blob checks; archive hash, sizes and toolchain belong in the external release evidence, not inside the archive being hashed |

The latest passing facts are recorded in [Current validation facts](current.md).
Historical reports in [the archive](../archive/2026-09/) are evidence for their
original revisions and do not close a current gate.
