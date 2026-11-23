# Current validation facts

> Status: local validation and explicitly labelled historical evidence; not production approval
> Scope: unreleased protocol suite, 0.7.0 alpha and historical release evidence
> Source: current working tree; exact revisions belong to local/CI evidence
> Last reviewed: 2026-11-23

Mooncakes published `0.7.0` on 2026-10-07. Its archive matches the frozen
distribution at `0967034` (SHA-256
`f7e3d2891f5e1ed943039f6438f396f77877c8d0045ef1fe5b06b068767477fa`).
[Hosted CI at that revision](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/37583031544)
passed the four target suites (455 Wasm, 324 Wasm-GC, 455 JS and 514 Native),
92 async integration tests and 131 Native TLS tests per OS on Linux, macOS and
Windows. These results describe the published alpha. The changes listed under
Unreleased in the changelog require their own validation.

## Native HTTP/3 hostname connections at `e1b4445`

The typed native client accepts an injected resolver for a UDP hostname.
HTTP/1, HTTP/2 and HTTP/3 use the same bounded candidate selection and DNS
deadline. The QUIC client attempts numeric peers in resolver order using one
handshake time budget. The HTTP origin and TLS identity retain their configured
hostname. A policy-denied lookup stops before DNS. A silent first peer can
use its share of the handshake budget and leave time for the next address.

One real-socket test resolves a transport name that differs from the TLS
identity, skips a policy-denied first address, and completes a response with
an unfinished upload. A second connection returns a transport-shaped error
from the application. The callback runs once and its exact error reaches the
caller. The case passed 16 additional times across four macOS processes.
The independent client fixture uses the native resolver for `localhost`.
`with_http3_connection` remains the lower-level numeric-peer entry point.

| Check at `e1b4445` | macOS arm64 | Ubuntu 24.04 arm64 VM |
| --- | --- | --- |
| Strict check, build and full suite | Wasm 503/503, Wasm-GC 361/361, JS 503/503, Native 572/572 | Native 572/572 |
| Native QUIC, TLS, client and listener packages, included above | 183/183 | 183/183 |
| curl, wget and nghttp real-socket H1/H2/h2c cases | 6/6 | 6/6 |
| Fresh authenticated connections to the MoonBit server during the impaired aioquic window | 58 in 121.159 s | 59 in 120.036 s |

Each OS also passed 256 requests on one connection and eight concurrent
requests. Across the VM gateway the Ubuntu ngtcp2/nghttp3 GnuTLS client
verified a byte-exact 4,096-byte echo, GOAWAY(4) and application close
0x100 from the macOS server. With the application roles reversed, the Ubuntu MoonBit
client resolved `localhost` using the native resolver. A UDP relay kept a
stable source port per connection and carried the traffic to macOS aioquic.
Concurrent echo and download matched all 4,096 and 131,072 bytes respectively.
The client rejected a mismatched certificate identity, and the independent
qlog recorded the expected application close.

The architecture check covered 28 manifests and 97 local dependency edges.
All 33 macOS native TLS ASan cases passed with leak detection disabled and
both input hashes restored. The 428-file frozen archive matched its Git
revision, passed the extracted four-target check, and had SHA-256
`1c7e6ec2a9ac9386d022f7cfc131075b585dbe708b4ae9c952a7737496b7f77e`.

The typed HTTP/3 client still serves one origin per scope. Multi-origin
pooling and local QUIC connection ID rotation remain implementation gaps.
The Windows candidate run, sustained traffic between separate physical hosts
and independent release-revision security review remain open.

## QUIC recovery under packet-tracking pressure at `0cb54c9`

With one ordinary tracking slot occupied by Initial CRYPTO, the previous
driver emitted nothing at the 997 ms probe deadline. Under the same limit,
the client now emits two 1,200-byte protected probes. After the receiver
delivers the CRYPTO bytes, an ACK for the original packet releases the shared
payload and leaves exactly 2,400 bytes in flight. A cumulative ACK releases
the remaining bytes. A separate test caps probe intervals at 1 ms, fills all
64 reserved records, checks the structured limit error, and uses delayed ACKs
to resume ordinary data and probe delivery.

The sender replaces a PADDING byte with PING when padded traffic would
consume the final ordinary slot or leave less than 1,200 bytes in its
congestion window. Tests check PADDING adjacent to an ACK, automatic packet
padding, a server Initial at the amplification limit, and preservation of packet
numbers and retry backoff when transmission is blocked.
[RFC 9000 section 13.2.7](https://www.rfc-editor.org/rfc/rfc9000.html#section-13.2.7)
and [RFC 9002 section 6.2](https://www.rfc-editor.org/rfc/rfc9002.html#section-6.2)

| Check | macOS arm64 | Ubuntu 24.04 arm64 VM |
| --- | --- | --- |
| Strict check, build and full suite | Wasm 502/502, Wasm-GC 361/361, JS 502/502, Native 569/569 | Native 569/569 |
| Native QUIC, TLS, client and listener packages, included above | 181/181 | 181/181 |
| HTTP/1.1, HTTP/2 and h2c real-socket interoperability | 6/6 | 6/6 |
| Impaired aioquic 1.3.0 connections, one new connection per request | 57 in 120.625 s | 58 in 120.177 s |

In separate runs on each OS, aioquic completed 256 requests on one connection
and eight concurrently on another. The reverse-role client checked a 4,096-byte
echo, a 131,072-byte download and hostname rejection. Both peer traces confirmed
the application close. The loopback listener test now claims its own UDP port.
The shutdown deadline case passed 32 additional times across four macOS processes.

At `e964926`, a test-only change replaced a detached HTTP/2 fixture producer
with the existing blocking reader. The isolated native header-write failure
case went from 60.00 s to under 0.01 s with the same cancellation and error
assertions. The full matrix above passed again. Across the VM gateway, the
ngtcp2/nghttp3 GnuTLS client received a byte-exact 4,096-byte echo, GOAWAY(4)
and an application close with code 0x100 from the macOS server.

The pinned compiler was `0.10.14+7d59c7ec9`. All 33 macOS Native TLS ASan
tests passed with leak detection disabled, and the runtime and manifest
hashes were restored. The frozen package at `e964926` contained 428 files
and passed its extracted four-target check. Its SHA-256 was
`9c9a5ecc3ee1c69aabc0677013cdc078f5ef4092ad08a6415f2ca7833f3c0979`.

Current Windows coverage, a sustained run between separate physical hosts,
and independent review of the release revision remained open. The following
revision added [HTTP/3 hostname connections](#native-http3-hostname-connections-at-e1b4445).

## QUIC recovery timers at `5e0f172`

Two regressions failed on the preceding revision. With Initial sends at 0 and
90 ms and a Handshake send at 40 ms, it probed Initial at 997 ms. The corrected
driver selects Handshake at 1,037 ms. In a second case the receiver acknowledged
a later packet at 80 ms and stayed silent. Polling now emits the missing stream
payload at 90 ms, and the receiver delivers it with its FIN.
[RFC 9002 sections 6.1 and 6.2](https://www.rfc-editor.org/rfc/rfc9002.html#section-6)

A client waiting for address validation can send a padded Initial or a
Handshake probe after its previous flight was fully acknowledged. Tests cover
both encryption levels, a server blocked at its amplification limit, capped
backoff, expiry on a silent peer and the three-PTO key-retention deadline on
a monotonic clock above the QUIC varint range. The packet driver consumes
validated ACK ranges without building a public event list. Standalone
recovery callers continue to receive per-packet notifications.

| Check | macOS arm64 | Ubuntu 24.04 arm64 VM |
| --- | --- | --- |
| Strict check, build and full suite | Wasm 499/499, Wasm-GC 358/358, JS 499/499, Native 566/566 | Native 566/566 |
| Native QUIC, TLS, client and listener packages, included above | 178/178 | 178/178 |
| Independent HTTP/1.1, HTTP/2 and h2c socket cases | 6/6 | 6/6 |
| aioquic 1.3.0 with loss, delay and reordering, fresh connections | 60 in 122.576 s | 57 in 120.350 s |

Each aioquic suite also completed 256 requests on one connection and eight
concurrent requests. The MoonBit client verified a 4,096-byte echo, a
131,072-byte download and hostname rejection against the upstream server.
The peer qlog confirmed the application close. Across the VM gateway the
ngtcp2/nghttp3 GnuTLS client received an exact 4,096-byte echo, GOAWAY(4)
and a 0x100 application close from the macOS server.

The pinned compiler was `0.10.14+7d59c7ec9`. The architecture check covered
28 manifests and 96 local dependencies. All 33 macOS Native TLS ASan tests
passed with leak detection disabled. Both ASan input hashes were restored.
The frozen archive contained 428 files, passed its extracted four-target
check and had SHA-256
`1ac27c61ef6b8abe287f5ebcf32efe1bdd0c047d41d711766ffac8b618bb9e03`.

Both operating systems ran on one physical machine. Current Windows results,
sustained traffic between separate hosts and independent release-revision
security review remained open. At this revision a full tracking queue could
prevent PTO probes until idle timeout. The [later pressure tests](#quic-recovery-under-packet-tracking-pressure-at-0cb54c9)
cover recovery from that condition.

## QUIC congestion and cumulative ACKs at `dd0c77b`

The original client sent a 1,200-byte Initial containing an ACK and automatic
PADDING while recovery reported zero bytes in flight. The packet builder now
computes the protected length before encryption, and the driver checks its
amplification, congestion and tracking budgets against that length. Padded
packets supply congestion feedback on ACK or loss, and retiring a key space
releases its outstanding bytes. ACK-only traffic can still pass a full window
when the packet has no PADDING. A focused test checks the original failure and
a second test forces a pending Initial ACK through a one-entry recovery queue.
[RFC 9002 section 2](https://www.rfc-editor.org/rfc/rfc9002.html#section-2)

The raw and TLS drivers share parsing for coalesced UDP datagrams and a bounded
received-range history. Tests cover missing numbers, reordered arrivals, ACK
retry, RTT sampling across mixed ranges, full packet numbers above 32 bits and
a 1,200-byte datagram composed of two independently authenticated Initials.

| Check | macOS arm64 | Ubuntu 24.04 arm64 VM |
| --- | --- | --- |
| Strict check, build and full suite | Wasm 493/493, Wasm-GC 352/352, JS 493/493, Native 560/560 | Native 560/560 |
| Native QUIC, TLS, client and listener packages, included above | 172/172 | 172/172 |
| Independent HTTP/1.1, HTTP/2 and h2c socket cases | 6/6 | 6/6 |
| aioquic 1.3.0 with loss, delay and reordering, one new connection per request | 56 in 120.735 s | 56 in 121.276 s |

On both systems the peer completed 256 requests on one connection and eight
concurrent requests on another. In the reverse role the typed MoonBit client
verified a 4,096-byte echo, a 131,072-byte download and hostname rejection.
Across the VM gateway the ngtcp2/nghttp3 GnuTLS client received the exact
upload bytes, GOAWAY(4) and an application close with code 0x100. The reverse
gateway run used a UDP relay with a stable source port per connection. The
aioquic qlog recorded the same application close. A per-datagram relay had
changed ports throughout the exchange and elicited a path validation error.

During the first guest run, parallel native compilation and the impairment
runner shared a 4 GiB VM. The guest kernel killed a C compiler under memory
pressure. On a separate connection the upstream client received its response
and sent a close, then exceeded the runner's 30-second process deadline.
The guest suite passed with one compiler job. The table reports the subsequent
standalone impairment run using the original timeout and loss settings.

The pinned compiler was `0.10.14+7d59c7ec9`. The architecture check covered
28 manifests and 96 local dependencies. All 33 macOS Native TLS ASan tests
passed with leak detection disabled, and the runtime and manifest hashes were
restored. The 426-file package passed its extracted four-target check with
SHA-256 `06155f8f820c6c890b8a0be6405b29b6d67d4a7557bcc2e724c6aa771bc3c481`.

The [subsequent timer validation](#quic-recovery-timers-at-5e0f172) covers
probe selection across packet-number spaces and time-threshold loss during
periods without incoming ACKs.

## HTTP/3 shutdown and QUIC frame handling at `abf4e1a`

The supervisor sends a GOAWAY boundary on each established HTTP/3 connection.
The listener tests check GOAWAY(0) on an idle peer and GOAWAY(4) on a
connection with one admitted request. The waiting caller receives the cutoff,
the admitted handler delivers all 32 KiB, and an expired shutdown deadline
cancels and joins a suspended handler and releases its UDP route. The cutoff
follows [RFC 9114 section 5.2](https://www.rfc-editor.org/rfc/rfc9114.html#section-5.2).

On macOS, a full-suite run exposed a race between an orderly peer close and
the server sending GOAWAY. Repeated duplex tests exposed a second race when
an earlier datagram send resumed during local shutdown. After both repairs,
four batches of 250 real-socket runs each completed all three requests, with
the 413 early response, one upload cancellation, byte-exact echo and trailers,
and a single completed connection.

QUIC frame encoding now checks the batch byte budget as it writes. A value
outside the 62-bit varint range previously aborted the Native process. The
public encoder now returns a typed error. ACK wire fields and caller-provided
ACKs share the same bounds. Recovery consumes validated incoming ranges
directly. A close-only packet also reaches the peer when the recovery queue
has no free slots.

| Check | macOS arm64 | Ubuntu 24.04 arm64 VM |
| --- | --- | --- |
| Strict check, build and full suite | Wasm 485/485, Wasm-GC 344/344, JS 485/485, Native 552/552 | Native 552/552 |
| Native QUIC, TLS, client and listener packages, included above | 164/164 | 164/164 |
| Independent HTTP/1.1, HTTP/2 and h2c socket cases | 6/6 | 6/6 |
| Impaired HTTP/3 window, one authenticated connection per request | 60 in 121.653 s | 56 in 120.579 s |

On each OS, aioquic 1.3.0 completed 256 requests on one MoonBit connection
and eight concurrent requests on another. Its 4,096-byte upload crossed the
initial 256-byte stream and 1,024-byte connection windows. In the reverse
role the typed MoonBit client verified a concurrent echo and 131,072-byte
download and rejected a mismatched TLS hostname. The aioquic qlog confirmed
the HTTP/3 application close code in both OS runs.

Across the VM gateway, Ubuntu's ngtcp2 0.12.1 / nghttp3 0.8.0 GnuTLS
client verified a 4,096-byte binary echo against the one-shot macOS server.
The independent trace recorded GOAWAY(4) on the server control stream and
CONNECTION_CLOSE frame type 0x1d with application error 0x100. With the roles
reversed, the Ubuntu MoonBit client completed the concurrent echo and download
against macOS aioquic through a UDP relay. The host qlog recorded the same
application close code.

The pinned compiler was `0.10.14+7d59c7ec9`. The package boundary check
covered 28 manifests and 96 local dependencies. All 33 macOS Native TLS
AddressSanitizer tests passed with leak detection disabled. The validation
script verified restoration of the runtime and package manifest. The frozen
425-file package passed its extracted four-target check with SHA-256
`2c1ca2436f5f22211656142986fddae94075f53a34bf91a8274da492629bfaba`.

The native HTTP/3 client still requires a numeric endpoint and manages one
origin connection per scope. At this revision QUIC recovery still omitted non-eliciting padded packets.
The [subsequent congestion and ACK record](#quic-congestion-and-cumulative-acks-at-dd0c77b)
covers the repair. Both OSes shared one physical Mac. Windows at the candidate revision, sustained capacity and recovery on
independent hosts, and independent security review remain open.

## Typed HTTP/3 applications at `e5ca13e`

HTTP/3 now runs the same streaming request handler as HTTP/1 and HTTP/2.
The native client sends concurrent `Request[B]` values to one authenticated
HTTPS origin and returns `Response[BodyStream]` as soon as final headers arrive.
The client and server share body streaming and HTTP/2 and HTTP/3 share request
target and pseudo-field construction.

The native regressions exercise a stalled handler alongside a streaming echo,
handler failure, cancellation with only one permitted stream, a server returning
413 during upload, and a completed response read after the peer closes. They
check that the next request can acquire the released slot, that a stopped
producer is cancelled once, and that response bytes and trailers survive.

| Check | macOS arm64 | Ubuntu 24.04 arm64 VM |
| --- | --- | --- |
| Strict check, build and tests | Wasm 479/479, Wasm-GC 338/338, JS 479/479, Native 544/544 | Native 544/544 |
| Native QUIC, TLS, client and listener packages (included above) | 157/157 | 157/157 |
| Independent HTTP/1.1, HTTP/2 and h2c socket cases | 6/6 | 6/6 |
| Impaired HTTP/3 window with one fresh authenticated connection per request | 58 in 121.681 s | 59 in 120.950 s |

Both OSes used the pinned MoonBit compiler `0.10.14+7d59c7ec9` and aioquic
1.3.0. On each OS the independent client also completed 256 requests on one
MoonBit connection, eight concurrent requests on another, and a 4,096-byte echo
across the configured stream and connection flow-control windows. The relay
introduced loss, delay and reordering with MoonBit serving. In the reverse
direction, the MoonBit client verified a concurrent 4,096-byte echo and
131,072-byte download against aioquic on direct loopback.

Across the VM gateway three simultaneous Ubuntu aioquic clients each posted
32 requests to the typed macOS listener. All 96 responses had status 200 and
matched the connection's distinct 4,096-byte payload byte for byte. In the
reverse role the Ubuntu MoonBit client additionally verified both responses,
rejected a foreign request origin and rejected a mismatched certificate hostname.
The macOS peer logged both requests and a normal HTTP/3 close on the same connection.

The macOS package boundary check covered 28 manifests and 96 local dependencies.
The frozen 425-file source package passed a strict four-target check after
extraction. Its SHA-256 was
`d725113a3c87eacbcb1953066b6bb1e276bfd405bf6cff3f551f6955fe3e6788`.

At this revision the typed client used one numeric endpoint per scope. The
later shutdown record above covers server-initiated GOAWAY. Both systems
shared one physical Mac.

## HTTP/3 client and listener at `4355e04`

The portable `Http3Session` drives client and server streams, shares message
validation in both directions, and retains blocked writes within bounded
queues. The native client opens an authenticated connection to a numeric UDP
endpoint. The native server routes multiple peers through one UDP socket and
keeps accepted peers reachable during supervisor shutdown. Applications
consume per-stream events and can send body chunks and trailers.

The release checks below used MoonBit compiler `0.10.14+7d59c7ec9` and
aioquic 1.3.0. Both operating systems ran on one physical arm64 Mac.

| Check | macOS arm64 | Ubuntu arm64 VM |
| --- | --- | --- |
| Strict check, build and suite | Wasm 478/478, Wasm-GC 337/337, JS 478/478, Native 540/540 | Native 540/540 |
| Native QUIC, TLS, client and server packages | 154/154 | 154/154 |
| Independent HTTP/1.1, HTTP/2 and h2c socket cases | 6/6 | 6/6 |
| Impaired HTTP/3 window with a fresh authenticated connection per request | 147 connections in 300.440 s | 142 connections in 301.793 s |

With MoonBit serving, the independent client on each OS completed 256
requests on one connection, eight concurrent requests on another, and a
4,096-byte echo across both connection and stream flow-control windows. It
also exercised key update and rejected an untrusted CA. The UDP relay
introduced loss, delay and reordering in this direction. With aioquic
serving on direct loopback, the MoonBit client verified a concurrent 4,096-byte
echo and 131,072-byte download on one connection. The peer observed the
normal HTTP/3 close. A separate handshake with a mismatched hostname failed
before the application callback.

Across the VM gateway, three independent Ubuntu aioquic clients connected
concurrently to the same macOS listener. Each issued 32 POSTs over one
authenticated connection. All 96 returned the expected 4,096 bytes, with a
distinct payload digest per connection. In the reverse role, the Ubuntu
MoonBit client completed the same concurrent echo and download against the
macOS aioquic server and rejected the mismatched hostname.

The macOS async integration subset passed 96/96. All 33 native TLS tests
passed under AddressSanitizer on macOS with leak detection disabled. The
manifest and runtime restoration hashes matched. Package boundaries and the
generated public interfaces passed their checks. The frozen source package
contained 421 files, passed a strict four-target check after extraction, and
had SHA-256 `e633ea0c8cf6577cc2d898ca314f7a2b34f94f8171615779b9d650cc2e07d469`.

At this revision the native HTTP/3 client managed one connection per scope
and applications consumed raw stream events. The later typed application
API and its validation are recorded above.

## Streaming and field handling at `9a58bfe`

The HTTP/1 decoder now applies line limits to the unread line and accepts
a CRLF split at the exact limit. Both HTTP/2 and HTTP/3 use the same rules
for regular fields in requests, responses and trailers. Native TLS sends
`close_notify` when a server handler succeeds and bounds the final flush.
Authenticated HTTP/1.1 chunked and HTTP/1.0 close-delimited responses both
completed on real sockets. Abrupt TCP EOF still produced a receive error.
A custom body producer received its original collection failure once.
Before the repair the regression observed two cancellation callbacks.

The same paired Go workload used at `ffd5394` ran on the Ubuntu arm64
guest with the same compiler versions. Each protocol ran four ten-second
windows in Go, MoonBit, MoonBit, Go order. All completed with zero errors.
The probe checked status, protocol and all 65,536 response bytes on every
request. The ranges below span the two windows per server.

| Protocol and server | Successful requests | Requests/s | P95 (ms) |
| --- | ---: | ---: | ---: |
| HTTP/1.1 cleartext, MoonBit | 85,032 | 4,237–4,266 | 1.025–1.027 |
| HTTP/1.1 cleartext, Go | 337,581 | 16,724–17,034 | 0.471–0.482 |
| HTTP/2 with TLS 1.3, MoonBit | 61,605 | 3,077–3,083 | 1.846–1.852 |
| HTTP/2 with TLS 1.3, Go | 130,156 | 6,127–6,888 | 0.973–1.232 |

The previous MoonBit throughput ranges were 1,675–1,679 requests/s for
HTTP/1.1 and 1,110–1,221 requests/s for HTTP/2. The two revisions ran in
separate sessions. These loopback measurements include the client and server
on the same guest. CPU cost, RSS and independent-host capacity remain
unmeasured by this workload.

The strict macOS four-target check, build and tests passed (476 Wasm, 335
Wasm-GC, 476 JavaScript and 535 Native). Ubuntu arm64 passed its strict
Native check, build and all 535 tests. The six independent TCP cases passed
on each OS. All 33 macOS AddressSanitizer tests in the Native TLS package
passed. The manifest and runtime restoration hashes matched. This macOS
ASan run had leak detection disabled.

With aioquic 1.3.0 through the impaired UDP relay, both systems completed
256 requests on one authenticated connection, eight concurrent requests,
a 4,096-byte flow-controlled upload, a key update and wrong-CA rejection.
The independent 60-second loopback windows completed 30 fresh connections
in 60.626 seconds on macOS and 28 in 60.382 seconds on Linux.

The frozen package contained 412 files, passed the four-target check after
extraction, and had SHA-256
`126068c9fabd53863912c1a4d92aee291a50c629100c292ec9faecfe74e1bd2a`. The HTTP/3 application
client/server API, Windows verification at the candidate revision, sustained
independent-host capacity and final independent review remain open.

## Native HTTP servers at `ffd5394`

The native listener serves HTTP/1.1 and HTTP/2 over TLS. A one-second
preflight against the preceding revision `7dbae42` exposed a full HTTP/2
control queue during four concurrent 64 KiB POSTs. The probe completed 942
requests and recorded 164 errors. The server now coalesces receive-window
credits before the writer flushes them. The same preflight on the corrected
code completed 1,228 requests with zero errors.

The paired release-mode comparison used an Ubuntu 24.04 arm64 guest with four
vCPUs and 4 GiB of RAM, Go 1.26.8 and moonc 0.10.14+7d59c7ec9. The same
four-worker Go client sent 64 KiB POSTs over loopback, verified the protocol,
status and exact response body, and recorded zero errors in all eight measured
windows. Each protocol used two ten-second windows per server with a separate
one-second warmup. Ranges below span the two windows. P95 uses up to 100,000
samples per window.

| Protocol and server | Successful requests | Requests/s | P95 (ms) |
| --- | ---: | ---: | ---: |
| HTTP/1.1 cleartext, MoonBit | 33,544 | 1,675–1,679 | 2.453–2.464 |
| HTTP/1.1 cleartext, Go | 344,858 | 17,160–17,325 | 0.462–0.470 |
| HTTP/2 with TLS 1.3, MoonBit | 23,311 | 1,110–1,221 | 4.653–5.526 |
| HTTP/2 with TLS 1.3, Go | 140,787 | 7,004–7,074 | 0.940–0.951 |

This workload exposes a throughput and tail-latency gap. CPU and RSS were
not measured. See the [benchmark method](../development/performance.md#go-nethttp-external-reference)
for the workload and collection procedure.

Strict macOS checks, builds and tests passed for Wasm (473), Wasm-GC (334),
JS (473) and Native (532). The focused async and Native QUIC/TLS suites passed
95 and 140 tests respectively. Ubuntu passed the strict Native build and all
532 tests. Six independent HTTP/1.1, HTTP/2 and h2c socket exercises passed
on each OS. The macOS client again completed 32 cold-start requests against
two Linux nghttpd 1.59.0 origins, each advertising one stream slot. The 16
responses from each origin matched on one connection, including the TLS
origin with verified h2 ALPN. The host and guest share physical hardware.

The frozen distribution contained 409 files and passed a strict four-target
check after extraction. Its SHA-256 was
`43d3ec0fbf2b28fdd06f35df8d806272bb1306ffadb1f480a4e55778384529ba`.
Open release work includes the general HTTP/3 client/server API, Windows at
the candidate revision, independent-host soak and capacity measurements, and
final independent review.

## Origin-managed HTTP/2 at `4d3dab7`

The pinned toolchain passed the strict four-target build and tests on macOS
(470 Wasm, 332 Wasm-GC, 470 JS and 529 Native), plus 93 async integration
tests and 140 Native QUIC/TLS tests. Ubuntu 24.04 arm64 also passed the strict
Native build and all 529 tests. The six independent HTTP/1.1, HTTP/2 and h2c
socket exercises passed on both systems.

The native pool on macOS concurrently issued 32 requests from a cold start
to two Linux nghttpd 1.59.0 origins through the VM's TCP port forward. Each
origin advertised one concurrent stream. Each served 16 successful requests
on one connection. One origin used cleartext prior knowledge. The other used
the test certificate as a trust anchor and negotiated TLS with `h2` ALPN.
The client checked status 200 and exact body bytes for every response.

The distribution contained 406 files and passed a strict four-target check
after extraction. Its SHA-256 was
`4d694086b4f02888a650536b2c42ba102485edff149e8204c0d3f9c5f6a2f190`.
The host and VM share physical hardware.

## Unreleased protocol suite at `128f9fd`

The pinned toolchain built and tested the clean revision on macOS. Wasm passed
465 tests, Wasm-GC 332, JS 465 and Native 524. A separate Ubuntu 24.04 arm64
guest passed the strict Native check, build and all 524 tests.

| Exercise | Observed result |
| --- | --- |
| HTTP/1.1, HTTP/2 and h2c | Six independent real-socket cases passed on each OS. |
| MoonBit HTTP/2 client against Linux nghttpd 1.59.0 | The macOS client used one cleartext HTTP/2 connection through the VM's TCP port forward. With a peer limit of one stream, the warm-up and all 32 concurrently submitted GETs returned the expected status and body. |
| Linux aioquic 1.3.0 against the macOS HTTP/3 server | All 32 POST requests shared one authenticated QUIC connection through a UDP relay on the VM gateway. Each 4096-byte echo matched the input SHA-256. |
| Impaired HTTP/3 loopback | Each OS completed a separate 256-request connection, an eight-request concurrent batch, a flow-controlled 4096-byte echo, a key update and wrong-CA rejection. The duration window completed 45 fresh connections in 91.848 seconds on macOS and 30 in 60.413 seconds on Linux. |
| Distribution | The frozen archive contained 401 files and passed a strict four-target check after extraction. SHA-256 was `e71923d13bca673acd7c25fe51cb4e0567320f5ff6ff68e9ddd03835d4a0c701`. |

These HTTP/3 runs used a host and guest on one physical machine.

## Earlier evidence

The earlier local security remediation and final validation are recorded in the
[2026-10-06 remediation index](../development/security-remediation-2026-10-06.md).
Clean revision `201e7ae` passed hosted CI run `37516695805`: Wasm 455/455,
Wasm-GC 324/324, JavaScript 455/455 and Native 514/514; async integration
passed 92/92 and Native TLS passed 131/131 on Ubuntu, macOS and Windows. The
run also passed interoperability, frozen package evidence and ephemeral
coverage generation. All 25 finding-index roots have local repairs and
regressions; scan coverage and production approval remain separate open gates.
The following table retains the earlier 2026-10-03 validation snapshot. Its
local and hosted results apply to their original source state; they are not
fresh cross-platform or interoperability evidence for the changed working tree.

| Suite | Result |
| --- | ---: |
| Wasm | 395/395 |
| Wasm-GC | 297/297 |
| JavaScript | 395/395 |
| Native | 450/450 |
| Async integration (historical) | 55/55 |
| Native TLS revocation regression (2026-10-03) | 31/31 |
| Native TLS AddressSanitizer (earlier macOS run) | 31/31; runtime and manifest restoration hashes match; leak detection unavailable |
| Native TLS identity suite, Ubuntu/macOS/Windows (historical hosted run) | 97/97 per OS |
| Real-socket HTTP/1.1, HTTP/2 and h2c (2026-10-03) | 6 cases passed |
| Independent HTTP/3 / QUIC TLS (historical) | GET, POST, key update, wrong-CA rejection; 8 concurrent streams passed |

Three impaired HTTP/3 / QUIC-TLS loopback windows were requested for 3600
seconds with eight concurrent requests. Each completed its requested window
and recorded loss, delay, reordering, recovery and certificate-negative cases.
The evidence was produced from a dirty local worktree, so it is bounded
loopback evidence rather than a clean cross-host or public-network release
claim. The repository's QUIC Retry, version negotiation, loss recovery and
stream state tests also passed in the four-target and Native suites.

Native TLS identity tests passed on all three operating systems, including
hostname, trust, expiry, SAN/wildcard, chain, mTLS, ALPN and credential-negative
cases. The independent HTTP/3 run also confirmed wrong-CA rejection.

The `0.7.0` archive excludes Native TLS testdata, including private keys and
certificate fixtures. A clean-tree package check records its exact file list,
sizes and SHA-256 in local or CI release evidence. Those generated files are
deliberately outside Git and the published archive; keeping the hash outside
the archive avoids a self-referential digest.
Resolved dependency versions are captured in that release evidence;
Moon does not provide a committed lockfile for this module.

The 2026-10-07 publication attempt exposed a gap in the earlier archive checks:
the TLS white-box tests imported a helper from excluded `repo-tools` sources.
The helper now lives in the included `internal/test_support` tree and remains
a test-only dependency. The distribution gate now checks all four targets from
an isolated extraction. Earlier inventory and Git-blob checks did not exercise
that step and must not be read as successful extracted-package validation.

The controlled method-v3 Native release HTTP/1 decoder comparison recorded a
passing local window:
median regression was -60.91% and geometric-mean regression was -61.01%, with
all six paired ratios and relative-noise checks within threshold. The earlier
`71512.a31c8121` window remains retained as `inconclusive-noisy`. The second
window was collected after that result, contrary to the method's no-retry rule;
it is supplementary evidence and does not supersede the inconclusive gate.
Neither result supports an HTTP/2, HTTP/3, TLS, QUIC, socket-capacity or
cross-platform performance claim. The later socket method-v6 result below is
the current scoped socket gate evidence.

The separately declared socket method-v2, method-v4 and method-v5 comparisons
remain immutable `inconclusive-noisy` evidence. Their raw windows were kept and
were not retried or reinterpreted. Method-v6 then used the documented 20-second
phase duration and retained all six AB/BA pairs in
local/CI evidence for the source revision.
All eight metrics passed: maximum relative noise was 4.62%, maximum pair cost
was 10.08% for HTTP/1 throughput, and every median/geomean cost stayed within
the 15%/20% limits. This closes only the declared local Native socket workload;
it is not a production-wide or cross-platform performance claim.

The Go `net/http` H1/H2 runner measured the Go baseline in the hosted release
run. The unreleased comparison at `ffd5394` above adds both servers on one guest.

The historical 2026-10-03 Standard security review is sealed under scan
`5e0f9eab-60e1-458a-b97a-e89b3a69aa48` with zero reportable findings and
partial coverage. It re-traced the six remediated protocol findings, the
standalone distribution checker and Native TLS credential parsing. External
dependencies, cross-platform archive metadata, public network and host
deployment remain outside its evidence. The final working-tree diff scan
`886a88d1-5078-4e4d-a1ea-3e0b96c1e822` also reports zero findings for the
changed TLS credential parser and distribution manifest, with the same local
scope limitations.

The subsequent two Deep Scans ended with 429/403 failures and partial coverage,
retaining 58 overlapping finding records against the same dirty snapshot.
The earlier zero-finding results are historical evidence. The
[2026-10-06 remediation index](../development/security-remediation-2026-10-06.md)
tracks all 25 distinct repair boundaries and their local verification. The
security gate still requires adequate coverage at the release revision; a new
complete scan or production security approval is not claimed.

The independent security-boundary review of commit
`391e415e5ce2bff3e4abc52d5c5cca80d9f60b1a` is sealed under scan
`d57f88d0-f034-4348-a694-8c7944a30d08`. It reported five medium findings and
one low finding: three HTTP/2 lifecycle/flow-control issues, QUIC CID history
growth, quadratic QPACK instruction processing, and multicast UDP source
misattribution. The report and coverage remain in the local security evidence
directory. This review covered the principal security boundaries, with partial
repository coverage; it is not an all-files
or dependency-vulnerability clean bill. Remediation validation is tracked
separately from the immutable report.

The continuation repairs the six reported controls and also exercises consumer
cancellation after END_STREAM, cancellation of suspended uploads, server early
responses after request-body cancellation, delayed Handshake packets with pending
CID retirements, and packet-space budgeting for retirement frames. Receive credit
is claimed only after the write lock is held, and is retired exactly once on
discard, so cancellation cannot lose a peer-visible flow-control update.
`BodyStream` now has a separate optional `on_cancel` callback; cancelling after
producer termination clears buffered frames while preserving the first terminal
cause and the once-only `on_terminate` contract. QUIC's driver still issues only
its initial local CID; this limitation is documented in
[`CID-SUPPORT.md`](../../protocol/quic/CID-SUPPORT.md).

Strict formatting, architecture, four-target check/build/test, generated
interfaces, distribution allowlist and six independent TCP interoperability
cases are recorded in local/CI evidence for their source revision. These raw
logs remain ephemeral and are not required to read this document.

Native OpenSSL CRL and stapled OCSP checks passed fresh, stale, future,
revoked, unknown, malformed and missing-staple cases with fail-closed behavior.
The implementation intentionally does not fetch OCSP responses online, and
Wasm requires a host-provided TLS/revocation capability. Historical security
reviews have the scoped limitations above. The open production gates include release-revision security coverage and
independent-host interoperability.

See [release gates](gates.md) for the remaining acceptance criteria and the
[GitHub Actions run](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/36837820455)
for the historical hosted log. Raw CI files from that run are not a current
package dependency or a release upload claim.
