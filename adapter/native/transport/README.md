# `adapter/native/transport`

> Status: Native adapter
> Scope: TCP/UDP sockets, resolver and clock implementations
> Targets: Native only

This package implements the `transport` contracts using the host runtime. Its
connectors receive a `NetworkPolicy` and authorize endpoints before opening a
socket. It is not imported by portable protocol code.

`UdpSocket` accepts only numeric unicast peers, including IPv4-mapped IPv6.
Multicast destinations are rejected before socket creation. `UdpServerSocket`
preserves each datagram's actual source and authorizes each peer operation.

`NativeResolver` returns unique unscoped IPv4/IPv6 results in system `getaddrinfo` order, up to `max_results`. Resolution runs outside the event loop. Timeouts release the caller while outstanding system lookups finish within a process-wide limit of 16 workers.
