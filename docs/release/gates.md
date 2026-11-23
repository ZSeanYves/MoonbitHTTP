# Release gates

> Status: canonical
> Scope: production approval for the 0.7.0 line
> Source: current working tree; exact revisions belong to local/CI evidence
> Last reviewed: 2026-11-23

Mooncakes published the 0.7.0 alpha on 2026-10-07. The table records the release baseline. Production approval remains open until every remaining gate below is
closed with evidence at the release revision. The [candidate record](current.md#http3-peer-restart-at-3bc9995) covers recovery after a live quic-go restart. The [CID rotation record](current.md#quic-frame-decoding-and-cid-rotation-at-015ae0c) covers the frame reader and rotation during an upload. The [pool validation](current.md#http3-origin-pooling-at-a30dcf8) covers origin reuse and bounded idle eviction.

| Gate | State | Required evidence |
| --- | --- | --- |
| Four target regression matrix | hosted baseline at `b098720` | [Hosted run 45149746301](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/45149746301) includes Linux, macOS and Windows Native jobs. The local counts at that revision were Native 592, Wasm 520, JS 520 and Wasm-GC 368. Wasm-GC executes synchronous tests. |
| Native TLS identity and negative suites | passed on clean hosted revision | Native TLS suite passed 131/131 on Ubuntu, macOS and Windows; the earlier 97-test-per-OS identity run remains historical evidence |
| HTTP/1, HTTP/2 and HTTP/3 interoperability | bounded runs passed at `3bc9995` | Six H1/H2/h2c socket cases per OS. A one-slot HTTP/3 pool recovered after a live quic-go restart on macOS and Ubuntu. Both H3 roles passed against aioquic. Its client qlog confirmed upload bytes on the replacement CID and its server qlog confirmed application close. Across the VM gateway ngtcp2 retired the old CID, received the next spare, and checked the echo, GOAWAY and close. The MoonBit client verified the reverse exchange against aioquic through a UDP relay. |
| QUIC Retry, version negotiation, loss recovery, stream concurrency | packet tracking at capacity and loss recovery passed at `0cb54c9` | The [candidate record](current.md#quic-recovery-under-packet-tracking-pressure-at-0cb54c9) covers both bounded impaired runs and eight concurrent H3 requests. Loss timers deliver missing stream data during silence, and probe scheduling covers multiple key spaces and anti-amplification backpressure. One-slot tests cover retransmission, delayed ACKs and data delivery. The timer has a separate 64-packet reserve and reports when that limit is reached. |
| Certificate identity and negative suites | configured suites passed on all three OSes | Hostname, expiry, chain, trust, wildcard, mTLS and wrong-CA rejection cases |
| Performance threshold and controlled old/new comparison | passed for the scoped socket workload | CI also runs a paired Native HTTP/1 decoder comparison with a frozen baseline, and the Go job measures both servers. Method-v6 historical evidence contains six AB/BA pairs for independent 20-second HTTP/1, HTTP/2 and cancellation phases; all 8 metrics passed behavior, regression and 10% noise checks. Scope remains local Native loopback only |
| Go `net/http` H1/H2 external reference | paired Ubuntu arm64 loopback runs at `ffd5394` and `9a58bfe` | All eight windows passed exact-response checks. MoonBit served 4,237–4,266 H1 and 3,077–3,083 H2 requests/s at the later revision. The [validation record](current.md#streaming-and-field-handling-at-9a58bfe) includes Go results, p95 and workload limits. |
| Long-duration QUIC/TLS interoperability | bounded single-connection run passed on one physical machine; sustained physical-host run open | The [native client measurement](current.md#sustained-http3-client-connection-at-ecb5d62) covered eight workers and 2,246 POST/GET pairs over 300.747 s through an impaired VM gateway. The separate-peer runner supports an independently hosted endpoint. Three historical 3,600-second impaired windows used a dirty loopback worktree. The redundant hosted loopback job was removed at the maintainer’s request. |
| Final security scan and review | known finding-index roots locally remediated; complete release-revision coverage still open | The two failed Deep Scans retained 58 overlapping records covering 25 repaired roots. Focused regressions, four-target checks and bounded H3 loopback validation passed; the three candidate-review paths were reproduced, repaired and covered by focused tests. See the [remediation index](../development/security-remediation-2026-10-06.md). The scans remain partial and earlier zero-finding scans do not close this gate for the changed tree |
| CRL/OCSP or documented deployment limitation | passed with scoped limitation | Native OpenSSL offline CRL and stapled OCSP checks cover freshness, identity, revocation and malformed inputs; online OCSP fetching and Wasm host providers are out of scope |
| Clean package and publication decision | published alpha verified | The 0.7.0 registry archive matches the frozen package at `0967034`. Hosted CI passed extracted-package validation. See the [release digest](current.md). |

The latest passing facts are recorded in [Current validation facts](current.md).
Historical reports in [the archive](../archive/2026-09/) are evidence for their
original revisions and do not close a current gate.
