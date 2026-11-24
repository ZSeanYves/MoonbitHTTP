# Running the test suites

Run from the module root. Each case belongs to one suite on each supported backend.

| Suite | Location | What it exercises |
| --- | --- | --- |
| `blackbox` | `tests/blackbox/<subject>_api/` | One package's public contract, including validation, codec vectors, policy decisions and backward compatibility. |
| `whitebox` | `*_wbtest.mbt` beside the implementation | Private state, functions and invariants within one component. |
| `integration` | `tests/integration/<scenario>/` | Components working together, including in-memory QUIC peers, HTTP request lifecycles and Native socket/TLS exchanges. |
| `integration` with private assertions | `*_integration_wbtest.mbt` beside the implementation | Peer exchanges that also check internal state such as pending ACKs or listener routing entries. The integration command includes these cases. |

```sh
moon run tests/run.mbtx -- blackbox native
moon run tests/run.mbtx -- whitebox native
moon run tests/run.mbtx -- integration native
moon run tests/run.mbtx -- verify native
```

Select `wasm`, `wasm-gc` or `js` in place of `native` for a portable backend. Append `--outline` to a suite command to list its cases. The `verify` command compares suite membership with Moon's complete test outline, including file and case index. Wasm-GC executes synchronous cases. CI checks representative async cases on Native, Wasm and JS.

To run one package directly, use its full path, for example `moon test tests/integration/quic_peers --target native`. Shared test doubles and the OCSP/CRL signer live in `tests/support/`. Certificates and keys live in `tests/fixtures/tls/`.

Independent implementation checks run separately in CI. HTTP/1.1 and HTTP/2 use `moon run repo-tools/tools/interoperability.mbtx` with curl, wget and nghttp. For HTTP/3, run `moon run repo-tools/tools/prepare_http3_interop.mbtx` to install the pinned peer, then `moon run repo-tools/tools/http3_interoperability.mbtx --reverse --impair`. Microbenchmarks live in `tests/benchmarks/` and run with `moon bench tests/benchmarks --target native --release`.

On macOS, run `moon run repo-tools/scripts/validate_native_tls_asan.mbtx` for the Native TLS suites with AddressSanitizer. The command instruments temporary copies of the checkout and SDK and writes per-run logs under `_build/native-tls-asan/`.
