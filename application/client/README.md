# `client`

> Status: public application API
> Scope: request execution, pooling and client policy over protocol drivers
> Targets: JS, Native, Wasm, Wasm-GC

`client` owns application-facing request lifecycle and connection reuse. It
receives transport capabilities and delegates framing to HTTP protocol
packages. Native socket construction belongs in [`adapter/native/client`](../../adapter/native/client/).

The 0.7 line is an alpha API boundary; consult [migration](../../docs/guide/migration.md)
before upgrading from 0.6.
