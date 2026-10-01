# `http1`

Status: canonical
Scope: public HTTP/1 codec and state package
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Implements incremental request/response decoding, start-line and field validation, body framing, trailers, and encoders without I/O.

## Entry points
Use RequestDecoder, ResponseDecoder, request/response events, and body framing encoders; use service for async Reader/Writer drivers.

## Dependencies and targets
Depends on types and codec; intended for Native, Wasm, Wasm-GC, and JS.

## Usage
Feed arbitrary fragments, consume every event, preserve over-read bytes, and select framing from the Body SizeHint through encoder APIs.

## Invariants and scope
Ambiguous lengths, illegal trailers, request-smuggling combinations, and invalid method/target/header forms are rejected. Lifecycle belongs to service or client.

## Canonical docs
- [Package map](../docs/concepts/packages.md)
- [Architecture](../docs/concepts/architecture.md)
- [Root guide](../README.md)
