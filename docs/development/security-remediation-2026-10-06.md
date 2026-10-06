# Security finding remediation — 2026-10-06

This change addresses the findings retained by Deep Scans
`0db80e97-3572-4dab-841b-696804688a35` (429) and
`b4007433-77aa-4ec4-a648-fbac53146a25` (403). Both scans ended `failed`
with `partial` coverage against revision `391e415e5ce2bff3e4abc52d5c5cca80d9f60b1a`
and a dirty working tree. Their 14 and 44 records include duplicate roots and
conflicting severity assessments. The table preserves every record by its
one-based position in the original `findings.json`; it is a remediation index,
not a replacement or successful completion of either scan.

The pre-change source, existing patch and verification logs are preserved in
the local validation workspace. They are not repository files, package
members, CI uploads or publication evidence. No new Deep Scan, external
service testing, publication, or hosted CI run is implied.

All 25 known roots below have local repairs and regression evidence in the
current working tree. The final continuation also closed the outstanding H2
EOF lifecycle and QUIC CID admission gaps, completed the H3 loopback control,
and restored a passing formatter check. This closes the known remediation
items locally; it does not change the failed/partial status of the two scans.

## Finding index

| Root | 429 record(s) | 403 record(s) | Control and extended validation |
| --- | --- | --- | --- |
| CI mutable action references | 1 | — | Resolve existing versions to immutable commits; validate workflow syntax |
| CI checkout credential persistence | 3 | — | Disable persistence in both jobs; validation output remains in the ephemeral CI workspace |
| H3 SETTINGS work | 2, 5, 12 | 5, 17, 20, 26, 32, 38 | Bound duplicate lookup in encoder and decoder; preserve unknown settings and order |
| Blocked QPACK ordering | 4 | — | Preserve request frame order, successive blocked sections and EOF; default-off mode remains supported |
| H2 response body ownership | 6 | 13, 41 | Cancel resource-owning bodies on header/data failure and reset; normal completion control |
| Scoped IPv6 peer identity | 7, 13 | 3 | Fail closed on unrepresentable peers without consuming fatal listener error budget |
| Complete cache representations | 8 | 4, 19, 28, 39 | Reject HEAD/206/Range/Content-Range storage; preserve GET-to-HEAD lookup and conditional HEAD refresh |
| Nameless cookie identity | 9 | — | Reject wire aliases before Secure/HttpOnly/prefix checks; preserve opaque nameless and ordinary named values |
| Mandatory cache revalidation | 10 | 16, 25 | Explicit error-fallback permission, response/request restrictions, transport-error and 5xx paths |
| 304 validator binding | 11 | — | Check actual outgoing condition and response validators before merge; preserve existing body on rejection |
| Content decoding completion | 14 | 12, 30 | Require upstream completion before decoded EOF; trailers, extra data and stacked coding controls |
| Cache-Control Unicode | — | 1, 22, 35, 44 | Delimiter scanning at code-unit boundaries; supplementary characters and quoted/escaped delimiters |
| TLS supervisor isolation | — | 2, 18, 21, 29, 37 | Contain peer timeout/raised failures; preserve healthy/new connections, external cancellation and accounting |
| QUIC public padding builder | — | 6 | Terminating length-varint sizing; boundary sizes, long token and ordinary packet controls |
| HPACK literal copying | — | 7, 27 | Decode views without full-block copies; literal/Huffman/integer and invalid-input cases |
| Graceful shutdown deadline | — | 8 | Start deadline on drain; wake accept, cancel remaining handlers, preserve unbounded None behavior |
| QUIC Initial key retirement | — | 9, 24 | Retire at relevant handshake/establishment boundaries; prevent late Retry/VN resurrection; preserve delayed Handshake ACKs |
| H1 unread body completion | — | 10, 31 | Wake blocked body producers on consumer completion; preserve lazy streaming responses |
| H2 EOF credit wait and task drain | — | 11, 36 | Wake current/future zero-credit waits; bound handler/body/writer drain after observed EOF; cancel incomplete h2c upgrade; preserve finite responses |
| QPACK blocked byte ownership | — | 14, 23, 33 | Transfer queued ownership atomically through replay failure/cancellation; charge all queued payloads |
| Empty custom TLS roots | — | 15 | Reject Some(empty) at common options boundary for stream/QUIC and client/server; None retains system defaults |
| H3 smoke constructor errors | — | 34 | Contain constructor/receive failures; bounded malformed loopback inputs followed by an authenticated HTTP/3 response |
| Refused-stream HPACK state | — | 40 | Decode/discard refused HEADERS and CONTINUATION; maintain shared state without dispatching rejected requests |
| H2 pre-upload ownership | — | 42 | Guard body before header writes and transfer ownership once; early error/cancellation and successful upload controls |
| h2c staged response ownership | — | 43 | Cancel staged response until transmitter accepts ownership; aborted drain/preface and normal upgrade controls |

The TLS supervisor entries represent one root, not five independent high
severity vulnerabilities. H2 EOF has differing high/medium assessments.
QPACK ordering and refused-stream HPACK synchronization were classified as
protocol defects by some workers and findings by others; correcting them does
not assert a new cross-principal exploit or broaden their original exposure.

## Final continuation and extended validation

HTTP/2 now has a finite post-EOF drain deadline. The default
`ServerConfig.h2_eof_drain_timeout_ms` is 30000 and validation rejects zero or
negative values. Finite responses may finish using available flow-control
credit; expiry fails the task group, cancels suspended handlers, response-body
producers and writers, and joins their cleanup. An h2c peer closing before its
initial SETTINGS now propagates a protocol error so the outer upgrade handler
and any staged response are also cleaned up.

Seven focused tests cover H2 and h2c, absent/partial initial SETTINGS,
suspended handlers and bodies, blocked response writes, finite delayed
responses, external cancellation and once-only cleanup. The pre-fix EOF and
incomplete-h2c cases failed with the test's outer timeout; all seven now pass.
The deadline starts when the read loop observes EOF, not when the connection
opens. Full `ServerConfig` literals must add the new field or use
`..ServerConfig::defaults()`. Like the existing async timeouts, cancellation is
cooperative: application code must yield and protected cleanup must terminate.
Explicitly setting the existing write timeout to `None` can still let a control
write block the read loop before EOF is observed; the default keeps finite I/O
timeouts. This is not a hard preemption mechanism for application code.

QUIC CID retirement also received extended checks from the earlier boundary
review. Both retransmission and recovery capacity are checked before attaching
pending retirement frames. Saturation preserves those frames and still allows
ACK-only progress. For a packet that requires a PATH_RESPONSE, same-packet ACKs
first release recovery capacity; if capacity remains exhausted, the packet is
deferred without committing receive history, CID or stream state. Retrying the
packet after capacity returns processes each effect once. Three encrypted-packet
tests cover queue saturation, a mixed CID/path/stream packet and ACK-last frame
ordering. The mixed-packet case failed before the admission fix; all three now
pass.

The earlier extension fixes remain covered by the full suite: direct
`H3SettingsFrame` inputs reject duplicate identifiers; blocked QPACK charges
the exact encoded frame size, including variable-length type and length fields;
and the H2 client closes its shared connection and cancels its reader before
joining a suspended upload after its callback returns.

A fresh independent candidate review found the incomplete h2c SETTINGS cleanup
and mixed QUIC packet admission gaps above. Both were reproduced and repaired.
Its disabled-I/O-timeout observation is documented with the EOF-observation and
cooperative cancellation limits above. The original candidate patch remains
separate from the final source; it is not evidence for the final fix by itself.

## Verification

The final source is based on revision
`391e415e5ce2bff3e4abc52d5c5cca80d9f60b1a` plus the preserved local changes and
this remediation. It is not a clean release revision. All commands below ran
from `/Users/winter/Documents/Moonbit/MoonbitHTTP`, with Moon commands serialized.

| Final validation | Result | Ephemeral local validation record |
| --- | --- | --- |
| `moon check --target all --deny-warn --warn-list +73` | Passed | local/CI log |
| `moon build --target all --deny-warn --warn-list +73` | Passed | local/CI log |
| `moon test --target all --no-parallelize --deny-warn --warn-list +73` | Native 511/511; Wasm 452/452; JS 452/452; Wasm-GC 323/323 | local/CI log |
| `moon info --target all` | Generated interfaces refreshed, including the new config field | local/CI log |
| `moon fmt --check` | Passed after formatting the existing dirty tree | local/CI log |
| `git diff --check` | Passed | Final working-tree check |
| Final H3 loopback fixture | Passed; malformed constructor/receive inputs followed by authenticated HTTP/3 200 and exact response body | `h3-smoke-final/result.json` and client/server logs |

The H3 probe used the cached, pinned aioquic 1.3.0 client on IPv4 loopback,
checked its source hash, sent four bounded malformed datagrams and verified a
subsequent TLS-validated `h3` response. The fixture was then cancelled and
reaped. The probe has a 40-second outer bound and performs no setup or downloads.
Its source is `h3_smoke_probe_v2.mbtx`; the final result records the executable,
server-main and client hashes. Earlier smoke evidence is retained separately.

`closure-baseline/` retains the pre-continuation source, and
`closure-source-sha256.txt` identifies the principal final source and regression
files. `closure-review.md` records the independent candidate review disposition.
Focused before/after logs are retained in the local validation workspace; no failing
baseline or partial scan has been replaced with a successful status.

Remaining evidence boundaries are partial repository scan coverage, third-party
dependencies, hosted platforms and real deployments. There is no remaining
known repair item from this finding index, but a complete security scan and
production approval are not claimed. The runtime's cooperative cancellation and
explicitly disabled I/O-deadline behavior are described above and in the service
README.
