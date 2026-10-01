# Current validation facts

> Status: canonical
> Scope: the latest completed 0.7.0 validation run
> Source: GitHub Actions run 36816204973 at revision `ee8496d365cf7f5aada0a4cf2cdf7a1b96b5391e`
> Last reviewed: 2026-10-01

The latest hosted run passed all configured jobs:

| Target or suite | Result |
| --- | ---: |
| Wasm | 361/361 |
| Wasm-GC | 281/281 |
| JavaScript | 361/361 |
| Native | 403/403 |
| Async checks | 55/55 |
| Native TLS on Ubuntu | 97/97 |
| Native TLS on macOS | 97/97 |
| Native TLS on Windows | 97/97 |
| Independent socket and impaired HTTP/3/QUIC checks | passed |

The run is [GitHub Actions run 36816204973](https://github.com/ZSeanYves/MoonbitHTTP/actions/runs/36816204973).
The generated 0.7.0 package recorded SHA-256
`1f6a5854aab537bf623e40c87936caad8511a7a0d963b3428bcf7cb312cab7dc`.

These facts establish the tested scope of that revision. They do not approve a
production release: performance thresholds, controlled old/new comparison,
long-duration external QUIC/TLS pressure, and the final security review remain
release gates. See [Release gates](gates.md) for the authoritative list.
