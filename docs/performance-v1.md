# v1 performance gate

`tools/performance_comparison.mbtx` compares a frozen source snapshot at
`77024d99398981806b9ca57fc374fd96832eec59` with the current worktree. It
creates a complete source manifest through MoonBit filesystem APIs, injects
the same benchmark package into both snapshots, builds both native release
executables before timing, checks their behavior oracle, and records executable
hashes, toolchain, machine, Git status, commands, stdout and stderr.

The workload is a fixed HTTP/1 request decoder operation: `POST /upload`,
`Host: example.test`, `Content-Length: 1024`, and a 1024-byte body. Each raw
sample performs 100,000 decodes after a fixed 10,000-operation warmup. Eight
raw samples are retained per arm in six interleaved AB/BA pairs. The timer is
monotonic and measures only the operation loop; compiler and process startup
are outside the sample. There is no trimming, winsorization or retry after a
noisy result.

The gate is explicit:

- each arm's sample standard deviation over all eight raw timings must be at
  most 10% of its mean; otherwise the result is `inconclusive-noisy`;
- current median regression must be at most 15%;
- every pair ratio and the geometric-mean ratio must be at most 20% slower;
- missing output, a failed behavior oracle, changed binary, timeout or process
  failure fails the run and retains the partial evidence.

This gate establishes evidence for one local HTTP/1 codec workload. It does
not claim HTTP/2 or HTTP/3 throughput, TLS or QUIC loss performance, socket
capacity, cross-platform performance, or a release-wide guarantee. Earlier
`moon bench` runs remain in `_build/evidence/performance/` as historical
evidence; the injected workload method is deliberately not merged with those
older measurements.

On 2026-09-30 the single method-v2 acceptance run completed in
`_build/evidence/performance/moonbithttp-performance.32792.d5104d08/` and
returned `pass-threshold`. Baseline median was 10,324.623 ns/op and current
median 10,354.711 ns/op: +0.2914%, inside the 15% regression ceiling.
The paired geometric mean was 0.995340 (-0.4660%); the largest individual
pair ratio was 1.023441 (+2.3441%). The largest relative sample standard
deviation was 8.2981%, below the unchanged 10% noise limit. All 96 raw
timings, including the slower samples, are retained in `result.json` and
per-arm stdout. No timing retry or outlier deletion was performed.

The preceding strict method-v1 run at
`_build/evidence/performance/moonbithttp-performance.19299.a1890263/`
remains `inconclusive-noisy`: one arm's reported relative sigma was 15.25%.
Method v1 used MoonBit core bench's approximately 100 ms internal batches
and winsorized summary. Method v2 was declared before its acceptance run and
uses fixed 100,000-operation batches, approximately one second each on this
machine, with every raw timing retained. Increasing the duration of each
sample reduces the relative effect of short scheduler interruptions without
relaxing the acceptance thresholds. The temporary method-v1 result under a
20% noise ceiling at `moonbithttp-performance.13830.2ea197bd` is retained but
is not accepted release evidence.

Run the build-and-oracle check without timing with:

```text
moon run tools/performance_comparison.mbtx --verify-only
```

Run the full controlled comparison from the repository root with:

```text
moon run tools/performance_comparison.mbtx
```
