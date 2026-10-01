# Package map

> Status: canonical
> Scope: package ownership and stability for the 0.7.0 development line
> Source: repository `moon.pkg` manifests and generated dependency graph
> Last reviewed: 2026-10-01

The physical tree mirrors the dependency direction. `0.7.0` is the breaking
migration line; package paths below are the canonical v1 alpha locations.

## Stable library surface

| Family | Packages | Responsibility |
| --- | --- | --- |
| Data core | `core/types`, `core/body`, `core/codec` | Requests, responses, headers, URI values, streaming bodies and reusable byte codecs. |
| Protocol engines | `protocol/http1`, `protocol/http2`, `protocol/http3`, `protocol/quic`, `protocol/tls` | Incremental framing, protocol state and protocol-specific errors. These packages do not open sockets. |
| Runtime contracts | `runtime/transport`, `runtime/service`, `runtime/detection` | Resolver, clock, policy, stream/datagram/TLS capabilities and connection lifecycle. |
| Application | `application/client`, `application/server` | Request routing, pooling and application policy built on protocol and transport contracts. |
| Optional policy | `policy/auth`, `policy/cache`, `policy/cookie`, `policy/content_coding` | Opt-in HTTP behavior that must not import protocol drivers. |
| Host adapters | `adapter/native/client`, `adapter/native/server`, `adapter/native/tls`, `adapter/native/transport`, `adapter/uv` | Native sockets, resolver, clock and TLS bindings; these are the only host-specific network entry points. |

`core/types` is the public data vocabulary. `core/body` owns streaming,
cancellation and backpressure. Protocol packages own framing and state.
`runtime/transport` is the capability injection boundary; Native clients receive
resolver, policy, clock and TLS explicitly.

## Development and verification

`internal/test_support` contains deterministic fixtures and fake capabilities used
by protocol and driver tests. `examples/cmd/*` contains smoke servers. Repository
automation lives in `repo-tools/tools` and `repo-tools/scripts`; none is runtime
API. Native TLS certificate fixtures remain under `adapter/native/tls/testdata`.

## Dependency direction

The generated graph is [reference/generated/dependencies.md](../reference/generated/dependencies.md).
The architecture checker validates every local `moon.pkg`:

```sh
moon run repo-tools/tools/check_architecture.mbtx
```

The intended direction is `core/types <- core/body <- protocol <- runtime/service <- application`,
with `runtime/transport` supplying capabilities. Optional policies consume core
contracts but do not reach back into protocol drivers. Portable packages cannot
import an `adapter/native/*` package.

## Stability

The 0.7 line is an alpha migration boundary. Public names may change at the v1
checkpoint; no compatibility facade is promised. A public declaration must be
documented in its package README, covered by a focused test and included
 deliberately in the distribution allowlist. See [architecture](architecture.md)
and [migration](../guide/migration.md).
