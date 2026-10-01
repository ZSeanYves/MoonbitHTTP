# Release gates

> Status: canonical
> Scope: production approval for the 0.7.0 line
> Source: current hosted evidence at `01a8f2cbcbac238642fe7fdf78ec000f2f881ee7`
> Last reviewed: 2026-10-01

The current hosted run validates the physical package migration and dependency
refresh. Production approval remains open until every remaining gate below is
closed with evidence at the release revision.

| Gate | State | Required evidence |
| --- | --- | --- |
| Four target regression matrix | passed on `01a8f2c` | Wasm, Wasm-GC, JS, Native check/build/interface/test; see [current evidence](current.md) |
| Native TLS Ubuntu/macOS/Windows | passed on `01a8f2c` | 97 tests per OS, including identity and negative cases |
| HTTP/1, HTTP/2 and HTTP/3 interoperability | bounded run passed on `01a8f2c` | Six real-socket H1/H2/h2c cases; independent impaired H3/QUIC TLS window for 60 seconds |
| QUIC Retry, version negotiation, loss recovery, stream concurrency | regression tests passed; extended external gate open | Protocol tests plus 8 concurrent H3 requests; multi-hour pressure remains required |
| Certificate identity and negative suites | configured suites passed on all three OSes | Hostname, expiry, chain, trust, wildcard, mTLS and wrong-CA rejection cases |
| Performance threshold and controlled old/new comparison | open | Frozen toolchain, workload, thresholds and both arms |
| Long-duration QUIC/TLS interoperability | open | Multi-hour external peer run with failure classification |
| Final security scan and review | open | Post-change scan artifact and disposition of findings |
| CRL/OCSP or documented deployment limitation | open | Tested behavior or an explicit accepted limitation |
| Clean package and publication decision | package verified; publication pending final gates | Allowlist, SHA-256, file list, revision and resolved dependency evidence |

The latest passing facts are recorded in [Current validation facts](current.md).
Historical reports in [the archive](../archive/2026-09/) are evidence for their
original revisions and do not close a current gate.
