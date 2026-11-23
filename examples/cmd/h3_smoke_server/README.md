# `examples/cmd/h3_smoke_server`

Status: development
Scope: Native HTTP/3 interoperability executable
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## Purpose
Provides a bounded loopback UDP fixture for HTTP/3 and QUIC interoperability. It is not a library or general-purpose server.

## Entry points
Run through repo-tools/tools/http3_interoperability.mbtx; it binds 127.0.0.1:18443 and serves bounded GET/POST cases.

Pass `--once` to initiate supervisor shutdown as soon as the first handler starts. The fixture then finishes that exchange over HTTP/3 and exits. This allows an independent peer to observe GOAWAY while its upload is still in flight.

POST requests also ask the peer to rotate the destination connection ID before the handler echoes the request body. The 256-byte initial stream window keeps a 4,096-byte upload in progress during rotation.

## Dependencies and targets
Uses `NativeHttp3Listener::bind` to access the connection and `serve_http3_connection` to run the streaming request handler. Native UDP and the OpenSSL QUIC TLS provider supply network I/O.

## Usage
Let the repository runner start and stop this executable. Never use its checked-in credentials for deployment.

## Invariants and scope
Connection, body, stream, and UDP work stays bounded; results are interoperability evidence, not pressure or performance guarantees.

## Canonical docs
- [Package map](../../../docs/concepts/packages.md)
- [Architecture](../../../docs/concepts/architecture.md)
- [Root guide](../../../README.md)
