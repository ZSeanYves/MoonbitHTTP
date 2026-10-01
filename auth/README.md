# `auth`

> Status: public optional policy
> Scope: HTTP authentication values and challenge helpers
> Targets: JS, Native, Wasm, Wasm-GC

`auth` contains opt-in authentication policy data. It depends on `types` and
does not own sockets, framing or connection lifecycle. Use it from a client or
server policy layer; keep credentials outside protocol state.

See [package map](../docs/concepts/packages.md) and the generated interface
for the current declarations.
