# Package map

> Status: canonical
> Scope: package ownership and stability for the 0.7.0 development line
> Source: repository `moon.pkg` manifests and generated dependency graph
> Last reviewed: 2026-10-01

Package count is a property of responsibility, not a score to minimize. A
package should own one coherent contract and depend in one direction. The
current paths remain flat during the 0.7 documentation phase; the planned v1
category directories are a later migration with a frozen API checkpoint.

## Stable library surface

| Family | Packages | Responsibility |
| --- | --- | --- |
| Data core | `types`, `body`, `codec` | Requests, responses, headers, URI values, streaming bodies and reusable byte codecs. |
| Protocol engines | `http1`, `http2`, `http3`, `quic`, `tls` | Incremental framing, protocol state and protocol-specific errors. These packages do not open sockets. |
| Runtime contracts | `transport`, `service` | Resolver, clock, policy, stream/datagram/TLS capabilities and connection lifecycle. |
| Application | `client`, `server` | Request routing, pooling and application policy built on protocol and transport contracts. |
| Optional policy | `auth`, `cache`, `cookie`, `content_coding`, `auto` | Opt-in HTTP behavior that must not import protocol drivers. |
| Host adapters | `client/native`, `server/native`, `tls/native`, `transport/native`, `uv_adapter` | Native sockets, resolver, clock and TLS bindings; these are the only host-specific network entry points. |

`types` is the public data vocabulary. `body` owns streaming, cancellation and
backpressure. Framing rules stay with protocol codecs and state machines.
`transport` is the only capability injection boundary; a client must receive
resolver, policy, clock and TLS explicitly on Native.

## Development and verification packages

`test_support` contains deterministic fixtures and fake capabilities used by
the protocol and driver tests. `cmd/*`, `tools`, and `scripts` are repository
automation and examples; they are not runtime API. Test files and Native TLS
certificate fixtures remain beside the package they validate so the published
archive can reproduce package tests, while command servers and historical
evidence stay outside the archive.

## Dependency direction

The generated graph is [reference/generated/dependencies.md](../reference/generated/dependencies.md).
The architecture checker validates it from every `moon.pkg` manifest:

```sh
moon run tools/check_architecture.mbtx
```

The intended direction is `types <- body <- protocol <- service <- application`
with `transport` supplying capabilities to drivers and adapters. Optional
policy packages may consume data contracts but must not reach back into a
protocol driver. Portable packages must not import a Native adapter.

## Stability

The 0.7 line is an alpha migration boundary. Public names may be removed at
the v1 checkpoint; no compatibility facade is promised. A public declaration
must be documented in its package README, covered by a focused test, and
included deliberately in the distribution allowlist. See
[architecture](architecture.md) and [migration](../guide/migration.md).
