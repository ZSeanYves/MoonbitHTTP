# `http3`

Status: canonical
Scope: public HTTP/3 codec, state, and driver
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Implements HTTP/3 frames, fields, SETTINGS/control streams, QPACK, request streams, connection state, and QUIC stream actions.

## Entry points
Use Http3Connection, Http3Driver, frame types, QpackField, and QPACK encoder/decoder APIs.

## Dependencies and targets
Depends on types, codec, and quic; protocol-core builds target Native, Wasm, Wasm-GC, and JS, while network use needs host adapters.

## Usage
Create connection state with explicit role/settings/limits, feed assigned QUIC stream events, and apply returned actions.

## Invariants and scope
Critical streams, duplicate fields, CONNECT settings gates, QPACK bounds, body lengths, and request lifecycle transitions are enforced here; sockets are outside.

## Canonical docs
- [Package map](../docs/concepts/packages.md)
- [Architecture](../docs/concepts/architecture.md)
- [Root guide](../README.md)
