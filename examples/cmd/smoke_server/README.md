# `examples/cmd/smoke_server`

Status: development
Scope: Native HTTP service smoke executable
Source: working-tree (governed by Git)
Last reviewed: 2026-11-23

## Purpose
Runs the bounded HTTP/1 and h2c service path used by local socket checks.

## Entry points
Run moon run examples/cmd/smoke_server through the repository interoperability runner.

## Dependencies and targets
Depends on service, body, types, and async sockets; +native only.

## Usage
The interoperability runner uses the default streaming handler. The paired Go comparison uses `--echo-h1 PORT` and `--echo-h2 PORT CERT KEY` with a bounded buffered handler, a loopback listener and the repository test certificate.

## Invariants and scope
This fixture does not define another protocol implementation or production configuration surface.

## Canonical docs
- [Package map](../../../docs/concepts/packages.md)
- [Architecture](../../../docs/concepts/architecture.md)
- [Root guide](../../../README.md)
