# `content_coding`

> Status: public optional policy
> Scope: HTTP content-encoding transforms and bounded decoding
> Targets: JS, Native, Wasm, Wasm-GC

`content_coding` handles representation coding around a streaming body. Limits
are explicit so decoding cannot silently allocate without a bound. Protocol
framing and transport remain outside this package.
