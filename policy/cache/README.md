# `cache`

> Status: public optional policy
> Scope: HTTP cache metadata and freshness policy
> Targets: JS, Native, Wasm, Wasm-GC

`cache` models cache decisions over `types` requests and responses. It does not
perform I/O or implement protocol framing. Enable it explicitly in an
application client.

See the [public interface](pkg.generated.mbti) for cache lookup and storage operations.
