# Performance methodology

> Status: canonical
> Scope: controlled performance comparisons for the 0.7.0 development line
> Source: working-tree (governed by Git)
> Last reviewed: 2026-10-01

Performance evidence is a separate release concern. Unit tests establish
behavior; socket interoperability establishes protocol interaction; neither
establishes throughput, latency or capacity. Current results and their exact
scope belong in [release/current.md](../release/current.md), while the required
thresholds are tracked in [release/gates.md](../release/gates.md).

## Controlled comparison

`repo-tools/tools/performance_comparison.mbtx` compares a frozen source revision with the
working tree under the same benchmark bytes, Moon toolchain, target and native
release settings. It must build both arms before timing, verify a behavior
oracle, record executable hashes and retain raw output. The timer covers only
the operation loop; compiler, process startup, setup and report generation
are outside the measured interval.

The default workload is an HTTP/1 request decoder operation. Each sample uses
a fixed warmup and a fixed operation count. Samples are interleaved in both
AB and BA order to expose drift between arms. Keep every raw sample: do not
trim, winsorize, retry a noisy run or delete a slow observation.

Run the behavior and build checks without timing with:

```text
moon run repo-tools/tools/performance_comparison.mbtx --verify-only
```

Run the complete comparison with:

```text
moon run repo-tools/tools/performance_comparison.mbtx
```

The tool reports median regression, paired ratios, geometric mean and relative
sample noise. Method version 3 uses 250,000 measured iterations per sample so
both the pre-migration and current decoder remain above the 500 ms minimum
sample duration. A result is `inconclusive` when noise exceeds the declared
limit or when the environment cannot provide comparable runs. Thresholds apply
only to the workload and target named by the report; they do not become an
HTTP/2, HTTP/3, TLS, QUIC, socket-capacity or cross-platform guarantee.

## Designing additional workloads

Add a workload only when it answers a concrete release question. Freeze the
request/response bytes, body sizes, stream count, loss profile, TLS provider,
CPU target and concurrency before collecting data. Separate warmup, setup and
measurement, and record machine, OS, compiler, dependency versions and power
or governor state when available.

For protocol workloads, cover at least one isolated codec operation and one
real-socket scenario. For HTTP/2 and HTTP/3, report multiplexing, flow-control
and cancellation behavior separately from raw throughput. For QUIC/TLS, report
handshake, loss recovery and key-update costs separately from steady-state
application traffic. A single aggregate score hides the boundary that failed.

Performance changes must be reviewed together with their behavior evidence and
allocation or buffering implications. Do not trade away protocol limits,
backpressure, cancellation or certificate checks to improve an unscoped local
benchmark.
