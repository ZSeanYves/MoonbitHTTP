# Fourth-round acceptance ledger

Baseline `37655164e23695acf8e9706a8284cb95bf06fd62`. Page numbers refer to the seven-page ecosystem review dated 2026-11-25. Candidate acceptance requires a new verification record on one immutable commit. Each result needs its platform, test entry, implementation revision and independent evidence. Registry installation of the candidate has a separate post-publication sign-off.

| ID | Review page | Finding | Original evidence | Candidate status |
|---|---:|---|---|---|
| 01 | 7 | HTTP/3 key update under loss/reordering | CI / loopback | Pending |
| 02 | 2 | Split Cookie at the H2/H3 handler | handler probe | Pending |
| 03 | 2 | HPACK before and after SETTINGS ACK | protocol probe | Pending |
| 04 | 2 | H3 request authority | protocol probe | Pending |
| 05 | 2 | GOAWAY direction and ordering | protocol probe | Pending |
| 06 | 2 | Asymmetric QPACK tables | protocol probe | Pending |
| 07 | 2 | Large Content-Length metadata | H1 probe / H2 source | Pending |
| 08 | 3 | H3 per-stage time budgets | Native loopback | Pending |
| 09 | 3 | H1 keep-alive drain | JS and Native / TLS source | Pending |
| 10 | 3 | Concurrent cache versions | JS and Native | Pending |
| 11 | 3 | 206 byte ranges | JS and Native | Pending |
| 12 | 3 | Stale-while-revalidate | JS and Native | Pending |
| 13 | 3 | Strong ETag comparison | public helper | Pending |
| 14 | 4 | Manual redirect responses | client probe | Pending |
| 15 | 4 | Buffered trailers | source | Pending |
| 16 | 4 | Encapsulation of live H3/QPACK state | public interface | Pending |
| 17 | 4 | Native listener error identity | source | Pending |
| 18 | 6 | OpenSSL trust sources | source / platform risk | Pending |
| 19 | 6 | Verified mTLS identity | source | Pending |
| 20 | 6 | Same-IP UDP port rebinding | source | Pending |
| 21 | 6 | Native TLS lifetime | ASan configuration | Pending |
| 22 | 6 | Backend capability matrix | source / CI | Pending |
| 23 | 5 | Paired H1/H2 service throughput | 8 local windows | Pending |
| 24 | 5 | Body path CPU, copies and latency | source / profile required | Pending |
| 25 | 5 | H2 origin pool saturation | source / capacity risk | Pending |
| 26 | 5 | Idle H3 scheduling | source / estimate | Pending |
| 27 | 5 | Sustained H3 connection reuse | soak coverage gap | Pending |
| 28 | 6 | Stable and candidate package consumers | registry consumer | Pending |

## Original witnesses

- Linux key update exceeded 30 seconds on [attempt one](https://github.com/ZSeanYves/http/actions/runs/45640592316/job/139297838354) and [attempt two](https://github.com/ZSeanYves/http/actions/runs/45640592316/job/139306176004). The first instrumented local combined-profile run also timed out after ALPN and the client key-update request. It received no complete response. Both proxy queues drained. Root cause remains open.
- Before hot-path changes, the corrected Go probe counted every successful request in its latency distribution. On the audit M4, H1 MoonBit windows measured 891.7/909.2 requests per second and 4.769/4.419 ms p95. H2 measured 874.5/825.3 and 6.223/6.473 ms. All eight Go/MoonBit windows verified the protocol, status and bytes. Final acceptance repeats baseline and candidate in alternating order on the same host.
