# Testing and validation

> Status: canonical
> Scope: repeatable development and release validation for the 0.7.0 line
> Source: working-tree (governed by Git)
> Last reviewed: 2026-10-01

MoonbitHTTP keeps four kinds of evidence separate: codec tests, protocol state
tests, driver integration tests and independent socket interoperability. A
passing unit-test matrix does not establish certificate validation, hostile
network behavior, sustained load or a performance threshold. Current measured
results belong in [release/current.md](../release/current.md); acceptance
criteria belong in [release/gates.md](../release/gates.md).

## Regression layers

| Layer | Location | What it proves |
| --- | --- | --- |
| Incremental codecs | `protocol/http1`, `protocol/http2`, `protocol/quic`, `protocol/http3` tests | Fragmentation, malformed bytes, bounded buffers and wire encodings |
| State transitions | Protocol state tests | Legal frames per phase, flow control, path validation, cancellation and terminal states |
| Drivers | `runtime/service`, QUIC driver and Native TLS tests | Reader/Writer integration, multiplexing, backpressure and endpoint actions |
| Independent sockets | `repo-tools/tools/interoperability.mbtx` and `repo-tools/tools/http3_interoperability.mbtx` | Behavior against real TCP/UDP sockets and an independent HTTP/3 implementation |

Test-only deterministic clocks, entropy and datagrams live in `internal/test_support`.
They make state transitions reproducible but are not network or deployment
evidence. Native TLS tests use the committed public fixtures in
`adapter/native/tls/testdata`; those credentials are never application credentials.

## Local checks

Run Moon commands serially because the compiler, test runner, benchmark runner
and interface generator share the module build directory and lock.

```text
moon fmt --check
moon run repo-tools/tools/check_architecture.mbtx
moon check --target all --deny-warn --warn-list +73
moon build --target all --deny-warn --warn-list +73
moon test --target all --no-parallelize --deny-warn --warn-list +73
moon info --target all
moon run repo-tools/tools/interoperability.mbtx
moon run repo-tools/tools/prepare_http3_interop.mbtx
moon run repo-tools/tools/http3_interoperability.mbtx --impair --concurrent-requests 8 --duration-seconds 300
moon coverage clean
moon coverage analyze -- -f cobertura -o coverage.xml
```

The four-target matrix covers Wasm, Wasm-GC, JavaScript and Native. Native-only
adapters and commands have no canonical Wasm interface; expected interface
differences are recorded by `moon info --target all` and must not be mistaken
for generated-interface drift.

`repo-tools/tools/check_architecture.mbtx` reads every local `moon.pkg`, distinguishes
main, test and wbtest imports, checks the layer rules, and compares the result
with the [generated dependency graph](../reference/generated/dependencies.md).
After an intentional manifest change, regenerate the graph with
`moon run repo-tools/tools/check_architecture.mbtx --write`, then review it as part of the
same change.

The socket interoperability runner requires `curl`, `wget` and `nghttp`. It
builds or receives an explicitly selected server binary, checks that the test
ports are free, bounds child-process execution, records each case separately,
and cancels and joins children before returning. A successful summary is valid
only when the required clients ran and their body and protocol assertions
passed.

The HTTP/3 runner uses a pinned aioquic client and an isolated virtual
environment. Its impaired mode injects loss, delay and reordering in both
directions and records packet counters, commands, versions, qlog, process
status and binary hashes. A bounded loopback run is useful interoperability
evidence; it is not a multi-hour WAN or capacity claim.

## Evidence discipline

Every report should identify the Git revision, module version, toolchain,
target, command, environment and artifact path. Keep raw timings, packet logs,
stderr and partial results when a run fails. Label evidence as one of:

- `pass`: the declared assertions completed;
- `fail`: an assertion or required check failed;
- `inconclusive`: setup, noise or missing capability prevented the declared
  assertion from being evaluated;
- `historical`: the report belongs to an older source snapshot.

Do not promote a historical report to current evidence by editing its old
numbers. Record a new run under the current revision and link it from
[current evidence](../release/current.md).

## Release handoff

Before packaging, run the clean-tree checks described in
`repo-tools/tools/release_evidence.mbtx`. The release report must include the exact Git
revision, generated interfaces, dependency graph, package file list, toolchain,
resolved dependency snapshot and SHA-256. Packaging and publication are
separate decisions; a green test matrix alone does not approve a release.
