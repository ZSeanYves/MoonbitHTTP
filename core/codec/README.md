# `codec`

Status: canonical
Scope: public protocol-independent codec primitives
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Provides bounded incremental byte buffering, line/prefix inspection, structured errors, and the shared RFC 7541 Huffman codec.

## Entry points
Use Buffer::new/feed/read_line/take and huffman_encode or huffman_decode.

## Dependencies and targets
Has no local package dependency; intended for Native, Wasm, Wasm-GC, and JS.

## Usage
Give Buffer an explicit maximum and feed arbitrary fragments; translate CodecError at the owning protocol boundary.

## Invariants and scope
Buffer growth is bounded. Huffman decoding rejects invalid codes, EOS in data, and invalid padding; HTTP field rules remain in protocol packages.

## Canonical docs
- [Package map](../../docs/concepts/packages.md)
- [Architecture](../../docs/concepts/architecture.md)
- [Root guide](../../README.md)
