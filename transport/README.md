# `transport`

> Status: public capability contract
> Scope: resolver, network policy, clock, stream/datagram and TLS interfaces
> Targets: JS, Native, Wasm, Wasm-GC

`transport` is the only capability injection boundary. Portable drivers depend
on these interfaces and never perform implicit DNS, socket creation or clock
access. Native implementations are in [`transport/native`](native/).
