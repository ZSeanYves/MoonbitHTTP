# `transport`

> Status: public capability contract
> Scope: resolver, network policy, clock, stream/datagram and TLS interfaces
> Targets: JS, Native, Wasm, Wasm-GC

`transport` is the only capability injection boundary. Portable drivers depend
on these interfaces and never perform implicit DNS, socket creation or clock
access. Native implementations are in [`adapter/native/transport`](../../adapter/native/transport/).

`resolve_endpoints` accepts an endpoint, lookup callback and `ResolveOptions`. Numeric endpoints pass through directly. Hostname lookups apply the configured deadline and result count, preserve candidate order, and keep the original scheme and port. The caller checks its network policy for the hostname and each numeric address it will connect to.
