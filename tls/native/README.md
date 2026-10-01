# `tls/native`

Status: canonical
Scope: public Native OpenSSL TLS and QUIC-TLS adapter
Source: working-tree (governed by Git)
Last reviewed: 2026-10-01

## Purpose
Implements TlsProvider and QuicTlsProvider with OpenSSL. It pumps TLS records or QUIC CRYPTO through injected connections and never performs DNS or socket creation.

## Entry points
Use NativeTlsProvider::new and NativeQuicTlsProvider::new with explicit trust anchors, PEM credentials, identity, and ALPN.

## Dependencies and targets
Depends on transport and Native OpenSSL FFI; +native only. Stream TLS needs OpenSSL 3; QUIC TLS needs OpenSSL 3.5+.

## Usage
Inject the provider into a client, listener, or QuicTlsDriver. h3 ALPN is a QUIC setting and does not turn TCP into QUIC.

## Invariants and scope
Certificate chain, validity, SAN identity, key matching, TLS version, and ALPN are checked before completion. 0-RTT is disabled; CRL/OCSP is not exposed by this API.

## Canonical docs
- [Package map](../../docs/concepts/packages.md)
- [Architecture](../../docs/concepts/architecture.md)
- [Root guide](../../README.md)
