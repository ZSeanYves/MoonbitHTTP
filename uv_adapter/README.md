# `uv_adapter`

Status: canonical
Scope: public callback-to-async I/O adapter
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Bridges callback-based runtimes to async Reader and Writer through CallbackTransport.

## Entry points
Use CallbackTransport::new with read, write, and optional close callbacks, then pass it to service.

## Dependencies and targets
Depends on moonbitlang/async/io only. It does not pin or import a particular uv release and has no Native socket dependency.

## Usage
Translate callback offsets and lengths exactly, close when the host transport closes, and pass the adapter to a service driver explicitly.

## Invariants and scope
Closed transports reject further operations and callback failures remain at the I/O boundary. It does not select protocol, resolver, TLS, or policy.

## Canonical docs
- [Package map](../docs/concepts/packages.md)
- [Architecture](../docs/concepts/architecture.md)
- [Root guide](../README.md)
