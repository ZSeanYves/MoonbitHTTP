# Release Evidence: 2026-09-22

This record describes the local worktree and artifact produced on 2026-09-22.
It is evidence for review, not a production approval.

## Inputs

- Repository: `ZSeanYves/MoonbitHTTP`
- Base Git revision (`HEAD`; worktree contains the changes recorded here): `72293b9d0f75d67054c5f59364024f18c2d5c6fb`
- Moon: `0.1.20260920 (914d7da 2026-09-20)`
- Moonc: `0.10.14+7d59c7ec9 (2026-09-18)`
- Dependency versions: pinned in `moon.mod`

## Strict gates

All commands ran from the module root with `--deny-warn --warn-list +73` where
applicable:

| Gate | Result |
| --- | --- |
| `moon fmt --check` | passed |
| `moon check --target all` | passed with `--deny-warn --warn-list +73` |
| `moon build --target all` | passed; host `libtool` reported only empty external stub objects |
| `moon test --target all --no-parallelize` | Wasm 284/284, Wasm-GC 221/221, JS 284/284, Native 298/298 |
| `moon bench --build-only --target native` | passed; HTTP/1 and HTTP/2 benchmark artifacts produced |
| `bash scripts/interoperability.sh` | curl/Wget HTTP/1.1, nghttp2 prior knowledge, h2c upgrade passed |
| `moon info --target all` | passed; native-only adapters are explicitly reported as non-canonical Wasm interfaces |
| `moon package --list` | passed; no stale duplicate `pkg.generated 2.mbti` files |
| `moon coverage analyze -- -f cobertura -o coverage.xml` | passed |
| Codex Security standard scan `bc7c3539-a1f8-40fd-b50c-7da74f86c6f1` | completed against the current worktree after the proxy and HTTP/3 fixes; 0 validated reportable findings; partial coverage, with delegated workers unavailable and the parent fallback used; native TLS/QUIC HTTP/3, long-run pressure/performance, generated/dependency line review, and independent review remain deferred |

## Post-baseline protocol fix

After the initial evidence snapshot, a QUIC driver regression was found and
fixed: `CryptoData` had been carrying the enclosing packet number where its
public contract requires the CRYPTO stream offset. A regression test now feeds
offset 3 before offset 0 while packet numbers differ, and checks that the
reassembled action reports offset 0. The all-target suite also drives 4,097
protected Initial packets through the receive path and verifies bounded packet
deduplication. The all-target test counts above include these regressions and
pass with the strict warning policy.

The current Codex Security report is at
`/private/var/folders/fv/gs2yjhx90sbch55yzczlpzk00000gn/T/codex-security-scans-L1W8eL/MoonbitHTTP/72293b9d0f75d67054c5f59364024f18c2d5c6fb_20260922T112813Z_hjt3wvg5/report.md`.
It reports no validated findings, but its partial coverage, token-record
warning, and deferred gates remain part of this evidence record.

## Post-baseline resource-bound fixes

The protocol/runtime hardening after the QUIC fix also closed three bounded
resource regressions. HTTP/3 now accounts for queued QPACK-blocked frames and
rejects a queue beyond `max_buffer_bytes`; completed non-critical unidirectional
streams are removed from the driver registry. HTTP/2 reclaims closed stream
flow-control records behind a fixed 1,024-entry tombstone history and caps a
header block across all CONTINUATION frames at `max_header_bytes`; consuming a
body after record reclamation restores only the connection-level receive window.
QPACK encoder pending dynamic-section metadata is bounded by the instruction
buffer budget and released on section acknowledgements or stream cancellation.
Connection-pool eviction notifications are bounded by `max_total`; capacity is
returned only after the resource-owning caller drains and closes evicted
sessions, so physical connections are never silently forgotten.
BodyStream wake-up notifications use a one-token bounded queue rather than an
unbounded event log. These paths have dedicated regressions, including 10,000
body frames, 1,100 closed HTTP/2 streams, bounded QPACK blocking and pending
sections, and the post-close flow-control callback.
Transport endpoint validation rejects embedded ports and malformed bracketed
hosts, while accepting only syntactically valid IPv6 literals when a host
contains a colon.

## Post-baseline proxy policy fix

Proxy forward and HTTPS CONNECT sessions now resolve the origin locally and
authorize every numeric candidate with `NetworkPolicy` before opening the
proxy connection or sending the origin authority. A denied private or loopback
candidate therefore stops both proxy modes before socket creation. Dedicated
forward-proxy and CONNECT regressions cover this boundary; the strict all-target
suite includes them.

HTTP/3 request field sections now validate method tokens and request targets,
require a parsed `:authority`, restrict ordinary requests to `http`/`https`
schemes, reject malformed or duplicate `Host`, and enforce
`Host/:authority` equality. Dedicated negative cases cover invalid scheme,
method, Host mismatch, missing authority, and malformed IP-literal authority.

## Current protocol-boundary hardening

The shared URI authority parser now accepts bracketed hosts only when they are
valid IPv6 or RFC 3986 IPvFuture literals. HTTP/2 service and HTTP/3 field
section tests verify that `[not-an-ip]` is rejected at the protocol boundary.
HTTP/1 response framing tests cover `Content-Length` rejection on 1xx, 204,
and successful CONNECT responses while retaining the legal HEAD/304 metadata
cases.

QUIC now authorizes the initial endpoint and every path-migration candidate via
`NetworkPolicy::QuicEndpoint` before mutating path state. Application streams
and application packets are rejected before connection establishment, and
0-RTT packet type is disabled unless an explicit replay policy is implemented.
Establishment also requires application packet keys, but this is still a
manual key-install capability rather than a TLS 1.3 handshake integration.

The Native HTTP/1 convenience package now also exposes an explicit-policy
factory. A Native `DenyAllPolicy` regression reaches `ClientPolicy` before any
socket operation, while the legacy factory remains available with its explicit
`AllowAllPolicy` compatibility default.

## Artifact

- Path: `_build/publish/ZSeanYves-MoonbitHTTP-0.6.0.zip`
- SHA-256: `a13fcf0a0a0412298cd6f46f47dcdd2909e75527b673f79c8af4a674a0c775ad`
- Contents: 221 files, 1,469,103 uncompressed bytes (393,308-byte archive)

## Open release gates

The following are intentionally not marked complete: native TLS custom trust
anchors/client certificates/server credentials, QUIC TLS 1.3 CRYPTO integration,
independent HTTP/3 client/server interoperability, certificate-chain negative
suite, long-running and pressure tests, repeatable performance thresholds, and
independent protocol/security review. The completed Codex Security scan found no
validated reportable vulnerability in the reviewed surfaces, but that scan
predates the current URI and QUIC changes and must be rerun before relying on it
as current evidence. Its coverage is partial and does not replace those
deferred gates. Until they are closed, the artifact is a validated development
build rather than a production-ready release.
