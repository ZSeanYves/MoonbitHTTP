# Release gates

> Status: canonical
> Scope: production approval for the 0.7.0 line
> Source: current working tree; exact revisions belong to local/CI evidence
> Last reviewed: 2026-11-23

Mooncakes published the 0.7.0 alpha on 2026-10-07. The table records the release baseline. Production approval remains open until every remaining gate below is
closed with evidence at the release revision. The [candidate record](current.md#quic-congestion-and-cumulative-acks-at-dd0c77b) covers both HTTP/3 roles on macOS and Ubuntu, including traffic across the VM gateway. Windows and separate physical hosts remain open for this revision.

| Gate | State | Required evidence |
| --- | --- | --- |
| Four target regression matrix | passed locally at `dd0c77b` | Wasm 493/493, Wasm-GC 352/352, JS 493/493 and Native 560/560 on macOS. Native 560/560 on Ubuntu. The [hosted alpha run](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/37583031544) remains the Windows baseline. |
| Native TLS identity and negative suites | passed on clean hosted revision | Native TLS suite passed 131/131 on Ubuntu, macOS and Windows; the earlier 97-test-per-OS identity run remains historical evidence |
| HTTP/1, HTTP/2 and HTTP/3 interoperability | bounded runs passed at `dd0c77b` | Six H1/H2/h2c socket cases per OS. Both H3 roles passed against aioquic. Across the VM gateway, ngtcp2 verified the echo, GOAWAY and application close, and aioquic confirmed the MoonBit client’s application close. |
| QUIC Retry, version negotiation, loss recovery, stream concurrency | PADDING accounting and cumulative ACK regressions passed at `dd0c77b` | The [candidate record](current.md#quic-congestion-and-cumulative-acks-at-dd0c77b) covers both bounded impaired runs and eight concurrent H3 requests. Timer-driven loss recovery and probe scheduling across packet-number spaces remain open. |
| Certificate identity and negative suites | configured suites passed on all three OSes | Hostname, expiry, chain, trust, wildcard, mTLS and wrong-CA rejection cases |
| Performance threshold and controlled old/new comparison | passed for the scoped socket workload | Method-v6 local/CI evidence contains six AB/BA pairs for independent 20-second HTTP/1, HTTP/2 and cancellation phases; all 8 metrics passed behavior, regression and 10% noise checks. Scope remains local Native loopback only |
| Go `net/http` H1/H2 external reference | paired Ubuntu arm64 loopback runs at `ffd5394` and `9a58bfe` | All eight windows passed exact-response checks. MoonBit served 4,237–4,266 H1 and 3,077–3,083 H2 requests/s at the later revision. The [validation record](current.md#streaming-and-field-handling-at-9a58bfe) includes Go results, p95 and workload limits. |
| Long-duration QUIC/TLS interoperability | historical loopback evidence passed; public cross-host evidence absent | Three requested 3600-second impaired aioquic windows passed with 8 concurrent requests; evidence came from a dirty loopback worktree; the redundant hosted loopback job was removed at the user's request |
| Final security scan and review | known finding-index roots locally remediated; complete release-revision coverage still open | The two failed Deep Scans retained 58 overlapping records covering 25 repaired roots. Focused regressions, four-target checks and bounded H3 loopback validation passed; the three candidate-review paths were reproduced, repaired and covered by focused tests. See the [remediation index](../development/security-remediation-2026-10-06.md). The scans remain partial and earlier zero-finding scans do not close this gate for the changed tree |
| CRL/OCSP or documented deployment limitation | passed with scoped limitation | Native OpenSSL offline CRL and stapled OCSP checks cover freshness, identity, revocation and malformed inputs; online OCSP fetching and Wasm host providers are out of scope |
| Clean package and publication decision | published alpha verified | The 0.7.0 registry archive matches the frozen package at `0967034`. Hosted CI passed extracted-package validation. See the [release digest](current.md). |

The latest passing facts are recorded in [Current validation facts](current.md).
Historical reports in [the archive](../archive/2026-09/) are evidence for their
original revisions and do not close a current gate.
