# `adapter/native/transport`

> Status: Native adapter
> Scope: TCP/UDP sockets, resolver and clock implementations
> Targets: Native only

This package implements the `transport` contracts using the host runtime. Its
connectors receive a `NetworkPolicy` and authorize endpoints before opening a
socket. It is not imported by portable protocol code.
