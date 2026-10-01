# `examples/cmd/h3_smoke_server`

Status: development
Scope: Native HTTP/3 interoperability executable
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Provides a bounded loopback UDP fixture for HTTP/3 and QUIC interoperability. It is not a library or general-purpose server.

## Entry points
Run through repo-tools/tools/http3_interoperability.mbtx; it binds 127.0.0.1:18443 and serves bounded GET/POST cases.

## Dependencies and targets
Uses adapter/native/transport, adapter/native/tls, quic, and http3; +native only. Four-target codec builds do not imply UDP support.

## Usage
Let the repository runner start and stop this executable. Never use its checked-in credentials for deployment.

## Invariants and scope
Connection, body, stream, and UDP work stays bounded; results are interoperability evidence, not pressure or performance guarantees.

## Canonical docs
- [Package map](../../../docs/concepts/packages.md)
- [Architecture](../../../docs/concepts/architecture.md)
- [Root guide](../../../README.md)
