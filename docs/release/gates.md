# Release gates

> Status: canonical
> Scope: production approval for the 0.7.0 line
> Source: working-tree (governed by Git)
> Last reviewed: 2026-10-01

The hosted matrix and the currently configured interoperability checks are
passing. Production approval remains open until fresh evidence closes every
gate below.

| Gate | State | Required evidence |
| --- | --- | --- |
| Four target regression matrix | closed for the recorded revision | A fresh hosted run after the next code change |
| Native TLS Ubuntu/macOS/Windows | closed for the recorded revision | Certificate identity and negative suites must remain green |
| HTTP/1, HTTP/2 and HTTP/3 socket interoperability | closed for the recorded revision | Independent clients and impaired UDP evidence |
| QUIC loss, Retry, version negotiation, stream concurrency | in progress | Reproducible window with packet-space and stream evidence |
| Certificate identity and negative suites | in progress | Hostname, expiry, chain, trust and rejected-suite cases |
| Performance threshold and controlled old/new comparison | open | Frozen toolchain, workload, thresholds and both arms |
| Long-duration QUIC/TLS interoperability | open | Multi-hour external peer run with failure classification |
| Final security scan and review | open | Post-change scan artifact and disposition of findings |
| CRL/OCSP or documented deployment limitation | open | Tested behavior or an explicit accepted limitation |
| Clean package and publication decision | pending final gates | Allowlist check, SHA-256, file list, revision and dependency evidence |

The latest passing facts are recorded in [Current validation facts](current.md).
Historical reports in [the archive](../archive/2026-09/) are evidence for their
original revisions and do not close a current gate.
