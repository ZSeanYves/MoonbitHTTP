# `server/native`

> Status: Native adapter
> Scope: Native server socket and capability wiring
> Targets: Native only

This package connects `server` lifecycle to Native sockets, resolver/policy,
clock and TLS providers. Policy is evaluated before network resources are
created; portable protocol packages stay independent of this adapter.
