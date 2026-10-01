# Migrating from 0.6 to 0.7 (toward v1)

> Status: canonical
> Scope: source migration from the 0.6 API to the 0.7.0 development line and
> its v1 architecture target.
> Source: working-tree (governed by Git)
> Last reviewed: 2026-10-01

The 0.7 boundary intentionally breaks compatibility. No deprecated forwarding
layer is required. Existing wire behavior tests remain; a removed stub is
replaced by real keyed-packet tests, and duplicated test fixtures move with
their owning concepts.

## Canonical entry points

| 0.6 concept | 0.7 location or API (v1 target) |
| --- | --- |
| `transport.Endpoint`, `IpAddress` | `types.Endpoint`, `types.IpAddress` |
| TLS contracts in `tls` | `transport.TlsProvider`, `TlsOptions`, `TlsError`, `SecureConnection` |
| Implicit native DNS/TLS/clock | `client/native.new_http1_client(resolver, policy, clock, tls_provider)` |
| Resolverless generic factory | `Http1Client::from_capabilities(connector, resolver, tls_provider, policy, clock)` |
| Optional callback policy/clock | Required `authorize` / `authorize_redirect` and `now_millis` arguments |
| Unchecked `BodyStream::new` / `try_new` | Checked `BodyStream::new`, returning `Result` |
| Multiple service client constructors | Checked `service.ClientConnection::new` with bounded phase deadlines |
| Nonpooled `Http1RoundTripper` | One pooled executor; lower-level streaming use belongs to `service` |
| Public parser/state internals | Private fields and checked transition methods |
| Stub `quic_protect_packet` | `quic_protect_packet_with_keys`, with explicit packet keys |
| `TlsOptions::validate` compatibility validator | `validate_client` / `validate_server`, sharing `validate_common` |
| `io` forwarding package | Official `moonbitlang/async/io` traits |
| Transport testing helpers | `test_support.FixedClock`, `ZeroEntropy`, `MemoryDatagramSocket` |

The callback executor may omit a resolver only for numeric endpoints. It still
requires explicit authorization and clock callbacks. The Native TCP connector
never looks up names; the client authorizes every resolver candidate before
connecting. UDP adapters similarly require a numeric endpoint and policy before
creating their socket.

## Reading the implementation

Start with data ownership (`types`) and injected capabilities (`transport`).
The `body` package contains only producers, consumers, queues and terminal
state. It does not know HTTP Content-Length, chunks or packet spaces.

Inside each protocol package, filenames expose the progression from bytes to
state transitions. HTTP/1 splits start-line/field/framing checks from request
and response decoders. HTTP/2 splits settings, streams, flow control and the
connection. HTTP/3 separates field validation, request/control streams and
QPACK encoder/decoder state. QUIC separates frame/packet codecs, connection
credit, path actions, loss recovery, datagram I/O and the TLS handshake bridge.

`service` binds HTTP/1 and HTTP/2 state to Reader/Writer lifetimes. It owns body
cancellation and connection shutdown. `client` owns request policy and physical
pool leases. Its HTTP/1 executor files separate capabilities, I/O adaptation,
connecting, proxy tunneling, pool sessions and exchanges; these are one
implementation in one package, not parallel facades.

The optional cookie/cache/auth/content-coding packages do not import protocol
drivers. HPACK and QPACK share a single immutable Huffman table and decoder in
`codec`. Test-only clocks and datagrams live in `test_support`, so production
capability packages do not export deterministic entropy substitutes.

## Validation after migration

Use the [four-layer test guide](../development/testing.md) and the checked-in generated
`.mbti` files. Test counts can increase as new boundary cases are added; test
count alone is not equivalence evidence. The frozen 0.6 source archive and
interfaces are recorded in the [archived baseline](../archive/2026-09/v1-baseline-2026-09-29.md).

Use `tools/check_architecture.mbtx --write` after intentional import changes,
then review the generated graph. CI checks the graph without rewriting it.
Native OpenSSL requires a supported runtime; failures to load it are explicit
capability failures, not successful TLS tests.
