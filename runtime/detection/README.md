# `auto`

Status: canonical
Scope: public protocol-selection helper
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Non-consuming detection of HTTP/1, HTTP/2 prior knowledge, and h2c upgrade prefixes. It only classifies input.

## Entry points
Use Detector::new, Detector::feed, Detector::buffered, select_protocol, and detect_h2c_upgrade.

## Dependencies and targets
Depends on types; intended for Native, Wasm, Wasm-GC, and JS.

## Usage
Feed fragments to one Detector and preserve buffered bytes for the selected service driver.

## Invariants and scope
Detection is bounded and non-consuming. It does not validate a complete exchange, select HTTP/3, or open a socket.

## Canonical docs
- [Package map](../../docs/concepts/packages.md)
- [Architecture](../../docs/concepts/architecture.md)
- [Root guide](../../README.md)
