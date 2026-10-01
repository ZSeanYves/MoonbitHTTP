# `test_support`

Status: development
Scope: test and white-box support; not a v1 runtime API
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Provides deterministic fragmentation, fault injection, recording writers, in-memory datagrams, fixed clocks, and zero entropy for tests.

## Entry points
Use fragment, FaultReader, RecordingWriter, MemoryDatagramSocket, FixedClock, and ZeroEntropy only from tests.

## Dependencies and targets
Depends on transport, async I/O, and types. Importable for tests but carries no v1 compatibility promise.

## Usage
Inject a fixture into a codec, driver, or capability contract and assert observable actions; keep failures and boundaries explicit.

## Invariants and scope
Fixtures are deterministic and bounded. ZeroEntropy and in-memory sockets are never production security or network providers.

## Canonical docs
- [Package map](../docs/concepts/packages.md)
- [Architecture](../docs/concepts/architecture.md)
- [Root guide](../README.md)
