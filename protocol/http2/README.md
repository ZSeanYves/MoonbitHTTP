# `http2`

Status: canonical
Scope: public HTTP/2 codec and state package
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Implements frame encoding/decoding, HPACK, stream and connection state, SETTINGS, GOAWAY/RST, and bounded flow control without I/O.

## Entry points
Use FrameDecoder, H2Connection, HpackContext, H2Frame, and frame encoding functions; use service for concurrent I/O dispatch.

## Dependencies and targets
Depends on types and codec; intended for Native, Wasm, Wasm-GC, and JS.

## Usage
Create a connection with explicit role and limits, feed frames, and apply returned actions. Keep body backpressure at the service boundary.

## Invariants and scope
Frame size, stream IDs, pseudo-fields, SETTINGS roles, HPACK bounds, and both flow-control windows are checked before state changes.

## Canonical docs
- [Package map](../../docs/concepts/packages.md)
- [Architecture](../../docs/concepts/architecture.md)
- [Root guide](../../README.md)
