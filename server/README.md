# `server`

> Status: public application API
> Scope: request dispatch and server connection lifecycle
> Targets: JS, Native, Wasm, Wasm-GC

`server` owns application dispatch and delegates protocol framing to the
protocol engines. Socket and TLS setup belongs in a host adapter such as
[`server/native`](native/).
