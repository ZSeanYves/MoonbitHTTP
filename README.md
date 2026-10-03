# ZSeanYves/MoonbitHTTP

MoonbitHTTP is a streaming HTTP foundation for MoonBit. Version `0.7.0` is
the breaking v1 architecture line and an alpha development release; it is not
yet a production-readiness claim.

## What it provides

- HTTP/1.1 and HTTP/2 framing, state machines and client/server orchestration.
- HTTP/3 and QUIC packet, stream and connection state, with TLS 1.3 integration
  points and explicit migration/interop gates.
- Shared `Request`, `Response`, `HeaderMap`, URI/authority, limits and layered
  errors in `core/types`.
- Streaming bodies with cancellation, backpressure and lifecycle ownership in
  `core/body`.
- Opt-in authentication, cookies, cache and content-coding policies.
- Explicit transport capabilities: resolver, stream/datagram I/O, clock,
  entropy, TLS and `NetworkPolicy`. Protocol code never opens a socket or does
  hidden DNS resolution.

The layering follows the shape of mature libraries such as Go `net/http` and
Hyper: protocol codecs and state machines are separated from transport and
application policy, and streaming is part of the request/response contract.
HTTP/1.1 and HTTP/2 have the broadest current coverage. HTTP/3/QUIC has passed
multi-hour independent QUIC/TLS pressure interoperability with controlled loss,
delay, reordering, recovery and concurrent streams. Cross-platform Native TLS
certificate identity and negative suites have also passed. This pressure run
uses a loopback peer and repeated connections, so it does not establish public-
network behavior or single-connection capacity. Native OpenSSL also supports
offline CRL checking and stapled OCSP verification with bounded freshness,
revocation and malformed-response rejection. Online OCSP fetching and a native
revocation provider for Wasm remain outside this release. The final security
review is still a release gate, so this project should be treated as a well-
tested development foundation rather than a finished standard-library
replacement.

## Native and Wasm

The portable packages (`core/*`, `protocol/*`, `runtime/*`, `application/*` and
`policy/*`) compile for Native, Wasm, Wasm-GC and JS. They contain protocol and
policy logic, but do not provide operating-system networking by themselves.

Native applications can use `adapter/native/*` for TCP/UDP sockets, resolver,
clock and OpenSSL-backed TLS; QUIC TLS requires OpenSSL 3.5 or newer. These
adapters are deliberately outside the portable import graph.

Wasm applications can use the same protocol and client APIs when the host
injects stream, datagram, resolver and TLS capabilities. MoonbitHTTP does not
assume browser sockets, DNS, UDP or TLS in Wasm, and a Wasm build must not
import `adapter/native/*`. A host such as MoonX may supply those capabilities;
the available network features then depend on that host.

## Where to go next

- [Getting started](docs/guide/getting-started.md) — construct a client with
  explicit capabilities.
- [Package map](docs/concepts/packages.md) — package ownership and target
  support.
- [Architecture](docs/concepts/architecture.md) — dependency and state-machine
  boundaries.
- [Validation and release gates](docs/release/current.md) — current evidence
  and unfinished production work.

The canonical package paths are listed in the [package map](docs/concepts/packages.md).
Moving a package changes its import identity and is a breaking change during
the `0.7.0` alpha line.

## License

Apache License 2.0. See [LICENSE](LICENSE).
