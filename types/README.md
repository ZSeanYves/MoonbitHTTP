# `types`

Status: canonical
Scope: public protocol-independent data and error core
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Owns validated Request, Response, HeaderMap, methods, versions, Uri, Authority, IP addresses, endpoints, dates, limits, and shared errors.

## Entry points
Use HeaderMap, Uri, Authority, Endpoint, IpAddress, Limits, and generic Request[B]/Response[B] records.

## Dependencies and targets
Has no local package dependency; intended for Native, Wasm, Wasm-GC, and JS.

## Usage
Construct through validating constructors and propagate typed errors. Keep the body parameter generic until an owning layer selects a Body implementation.

## Invariants and scope
Header names, URI authorities, IP literals, methods, and limits are validated at construction. No framing, socket, TLS, resolver, or policy implementation lives here.

## Canonical docs
- [Package map](../docs/concepts/packages.md)
- [Architecture](../docs/concepts/architecture.md)
- [Root guide](../README.md)
