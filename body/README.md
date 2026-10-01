# `body`

Status: canonical
Scope: public core body and backpressure contract
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Defines the protocol-independent Body stream, Frame, SizeHint, bounded queues, cancellation, and explicit collection.

## Entry points
Use EmptyBody, FullBody, QueueBody, BodyStream, BodyStream::from_pull, and collect; implement Body::next_frame and size_hint.

## Dependencies and targets
Depends on types and the async queue capability; intended for Native, Wasm, Wasm-GC, and JS.

## Usage
Use FullBody for known bytes, QueueBody for finite frames, and bounded BodyStream for producer/consumer work. Give collect an explicit maximum.

## Invariants and scope
The stream preserves Data, Trailers, completion, cancellation, and terminal errors. Queue and collection limits are enforced; framing stays in protocol packages.

## Canonical docs
- [Package map](../docs/concepts/packages.md)
- [Architecture](../docs/concepts/architecture.md)
- [Root guide](../README.md)
