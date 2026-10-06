# Performance methodology

> Status: canonical
> Scope: controlled performance comparisons for the 0.7.0 development line
> Source: working-tree (governed by Git)
> Last reviewed: 2026-10-06

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

## Controlled HTTP/1 and HTTP/2 socket comparison

`repo-tools/tools/socket_performance_comparison.mbtx` freezes baseline
`391e415e5ce2bff3e4abc52d5c5cca80d9f60b1a` and the current working source into
separate snapshots. Both arms must contain identical smoke-server handler and
package bytes. Both use the same frozen copy of `stress.mbtx`, payload, client
tools, concurrency and native release settings. This baseline measures the
pending changes against the last committed implementation; it does not replace
the older codec baseline. Source manifests, tool and dependency versions,
commands, executable hashes, the plan and every completed or failed window are
retained under `_build/evidence/socket-performance/`.

Run from the repository root, with `curl`, `nghttp`, `ps`, `git` and `tar`
available and local port 18080 free:

```text
moon run repo-tools/tools/socket_performance_comparison.mbtx --verify-only
moon run repo-tools/tools/socket_performance_comparison.mbtx
```

`--verify-only` builds both servers and runs a one-second behavior window on
each. It checks exact echo bodies, HTTP/1 connection reuse, three successful
HTTP/2 streams, intentional slow HTTP/1 upload cancellation and successful
requests after cancellation. These oracle windows produce timings as diagnostic
data, but take no comparison windows and make no performance conclusion. Both
builds and oracles must pass before a full run starts its paired measurements.

Method version 1 uses six pairs in AB, BA, AB, BA, AB, BA order. Every arm starts
a fresh server, warms both protocols, then admits batches for ten seconds using
six workers (three per protocol), three requests per batch and 65,536-byte echo
bodies. One additional worker repeatedly cancels a slow HTTP/1 upload using a
50 ms client deadline. Admitted batches finish before the timer stops; recovery
probes and server shutdown follow outside that interval. Compilation occurs
before a window begins. No source edits or parallel builds should run during
source capture or the measurements.

The report separately compares HTTP/1 and HTTP/2 verified requests per second,
their p95 batch latency, maximum sampled server RSS and p95 cancellation-process
latency. A batch includes client process startup, three requests and output
collection. It is not a single-request latency measurement. Cancellation time
ends at the expected client timeout exit; post-cancellation requests check
continued service, not the time at which server tasks or memory are reclaimed.
HTTP/2 reset/cancellation behavior is outside this workload. RSS is sampled every
250 ms and is not an allocation count or leak proof. HTTP/1 and HTTP/2 share the
same mixed-load window, so their rates are not isolated protocol capacities.

All comparisons use a cost ratio: baseline/current for throughput and
current/baseline for latency and RSS. Each metric must stay within 15% median
cost regression and 20% for every pair and the geometric mean. A within-arm
relative standard deviation above 10% for any metric makes the whole run
`inconclusive-noisy`, even if ratios meet their thresholds. These are local
workload thresholds, not release-wide acceptance limits. Power/governor state
is not controlled, and no cross-host, cross-platform, HTTP/3, TLS or QUIC claim
follows from this result.

Method version 2 is a separately declared follow-up workload for a noisy mixed
window. It keeps the same frozen baseline, six AB/BA pairs, 15% median and 20%
pair/geomean cost limits, and 10% within-arm noise limit, but measures HTTP/1
and HTTP/2 in independent windows. The HTTP/1 phase retains the slow-upload
cancellation worker; the HTTP/2 phase removes cross-protocol and cancellation
load so its tail latency is attributable to its own protocol path. It records
the protocol in every stress result and retains every raw batch, RSS and
cancellation observation. A v2 result is valid only when both protocol phases
pass their behavior oracles and every phase metric is below the same thresholds.
The v1 noisy result remains immutable evidence and is not reinterpreted.

Method version 3 is another independently declared follow-up. It keeps the v2
protocol isolation and all thresholds, but fixes a larger batch size of 12
verified requests per client process. This amortizes process startup while
retaining the raw batch p95 rather than replacing it with an aggregate or
trimmed statistic. The HTTP/1 phase still includes cancellation and the HTTP/2
phase still excludes cross-protocol load. A v3 result is accepted only when
both phases pass all behavior, noise and regression checks.

Method version 4 isolates the remaining cancellation measurement. It runs
HTTP/1 throughput and tail latency without a cancellation worker, HTTP/2 in its
own phase, and a cancellation-only phase with no normal request workers. The
cancellation phase doubles the admission duration and samples every 25 ms;
the same raw p95, pair, geomean and 10% noise rules remain in force. This keeps
the cancellation signal separate from request scheduling and does not relax
the acceptance criteria.

Method version 5 keeps method 4's isolated phases and extends only the HTTP/2
admission window to 20 seconds after the 10-second H2 p95 baseline remained
slightly noisy. Method version 6 extends all three isolated phases to 20
seconds, preserving six AB/BA pairs, 12 verified requests per batch, 25 ms
cancellation sampling, the same p95 calculation, regression limits and 10%
within-arm noise limit. The method change addresses short-window scheduler
transients; it does not trim, retry, replace or reinterpret any method 4 or 5
observation. Only a complete method 6 result with all metrics below the same
limits can close the scoped socket-performance gate.

Keep every raw worker timing, RSS sample, cancellation record, failed output and
per-window result. Successful response bodies are verified and retained as
length/hash records against the frozen payload; failure bodies and stderr are
saved in full. Never trim, retry, replace or discard an unfavorable observation.
An execution failure preserves partial evidence and yields no comparison
conclusion. An incomplete or noisy run does not close the performance gate.

## Designing additional workloads

## Go `net/http` external reference

`repo-tools/tools/go_net_http_reference.mbtx` prepares a standard-library Go
fixture at `repo-tools/tools/go_net_http_reference/main.go`. The fixture serves
the same bounded POST echo workload over HTTP/1.1 cleartext and HTTP/2 TLS with
ALPN, and its probe reports throughput, p50/p95 latency and a response-body
oracle. Use the same payload size, connection reuse, concurrency, request
count/duration, CPU environment and toolchain metadata for both implementations;
run the H1 and H2 windows in AB/BA order when MoonBitHTTP endpoints are supplied.

The fixture is an external reference, not a release threshold and not an HTTP/3
comparison. The runner keeps the binary, raw windows and logs in the ephemeral
local/CI evidence directory. If `go` is unavailable it writes an explicit
`not_run` result; a missing Go toolchain must never be silently reported as a
passing comparison. The current service layer does not provide a generic H3
service, so H3 remains outside this reference workload.

Run it from a checkout with Go installed:

```text
moon run repo-tools/tools/go_net_http_reference.mbtx
```

When Go is available, the runner measures a Go H1/H2 baseline with an in-process
`httptest` server and records a concentrated JSON summary. A comparison is
valid only when a caller also runs the same probe against MoonBitHTTP H1/H2
endpoints, uses the same workload in AB/BA order and both behavior oracles pass.
CPU, RSS and cancellation measurements remain separate metrics and must be
reported as unavailable when the harness does not collect them.

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
