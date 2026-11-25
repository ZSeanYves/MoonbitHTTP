# Native HTTP server development profiles

These measurements compare 3765516 with integrated source 47ff8c2 on an Apple M4 with 4 performance cores, 6 efficiency cores and 16 GB RAM. The host ran macOS 26.5.2 arm64, Moon 0.1.20261119, moonc v0.10.22+124d61d05, OpenSSL 3.6.3 and Go 1.27.4. All traffic used loopback. H1 used cleartext with up to one connection per worker. H2 used TLS and a single connection shared by all workers.

## Timed profiling windows

The allocation and wait probe used four workers, a 64 KiB POST with an exact byte-for-byte echo, a one-second warmup and one three-second measurement per revision and protocol. Each entry below divides the server's window delta by completed requests.

| Per successful request | H1 baseline | H1 integrated | H2 baseline | H2 integrated |
|---|---:|---:|---:|---:|
| MoonBit runtime allocation bytes | 945,497 | 399,709 | 1,600,532 | 1,208,788 |
| MoonBit runtime allocation calls | 582.25 | 176.57 | 629.49 | 395.07 |
| Bytes copied in runtime bulk operations | 457,469 | 319,959 | 936,335 | 578,046 |
| Server user + system CPU, µs | 370 | 80 | 481 | 262 |
| Outbound DATA writes | — | — | 4.00 | 1.00 |
| Contended outbound DATA lock acquisitions | — | — | 3.94 | 1.00 |
| Time waiting for the outbound DATA lock, µs | — | — | 445 | 89 |
| Waits for additional outbound DATA flow credit | — | — | 0 | 0 |

The allocation counter measures raw allocation requests made through the compiled MoonBit runtime, including object headers and array padding. The copy counter records the sizes passed to runtime `memcpy` and `memmove` operations. Scalar copies in generated code, OpenSSL allocations and copies, kernel copies and the Go client are outside those counters. CPU time includes the entire server process. It comes from macOS `ps` with 10 ms resolution. RSS is an endpoint observation. Lock and credit timers cover the outbound DATA writer and count independently. Go advertised ample response credit in this workload.

Separate four-second runs used the ordinary release executable and macOS `sample` for two seconds at a nominal 1 ms interval. Top-of-stack sample counts include sleeping threads. H1 throughput was 910 and 5,531 requests/s, with p95 at 4.60 and 0.81 ms. H2 throughput was 892 and 1,379 requests/s, with p95 at 6.30 and 3.08 ms. The release gate uses paired windows and an independent run. [Filtered CPU samples and probe measurements](cpu-samples.json)

## Per-change counter profiles

One one-second warmup and one three-second profiled echo window were run at each source revision. Each change is paired with its direct parent. Revisions separated by unrelated commits have their own parent window. Values for allocation, bulk copies, process CPU, DATA lock wait and DATA writes are per successful request.

| Protocol | Source | Allocated B | Runtime bulk copy B | CPU µs | DATA lock wait µs | DATA writes | req/s | p95 ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| H1 | `eb459b0` | 945,484 | 457,469 | 379 | 0.0 | 0.00 | 930 | 4.41 |
| H1 | `44e7501` | 399,699 | 319,965 | 79 | 0.0 | 0.00 | 5,633 | 0.79 |
| H2 | `eb459b0` | 1,593,962 | 934,335 | 491 | 449.3 | 4.00 | 862 | 6.35 |
| H2 | `44e7501` | 1,205,356 | 672,744 | 407 | 417.3 | 4.00 | 967 | 5.80 |
| H2 | `0eb3844` | 1,140,387 | 608,129 | 453 | 438.2 | 4.00 | 898 | 6.05 |
| H2 | `c5e9527` | 1,135,765 | 607,268 | 451 | 435.3 | 4.00 | 908 | 5.98 |
| H2 | `e8a217c` | 1,116,648 | 645,991 | 375 | 400.5 | 4.00 | 1,039 | 5.32 |
| H2 | `4d6ece2` | 1,123,249 | 646,079 | 376 | 404.2 | 4.00 | 1,027 | 5.46 |
| H2 | `fb90ef3` | 1,209,581 | 578,087 | 285 | 89.9 | 4.00 | 1,438 | 2.88 |
| H2 | `b106095` | 1,208,799 | 578,029 | 268 | 89.8 | 1.00 | 1,368 | 3.06 |

At 44e7501, H1 begins serving the original reader after peeking at the preface, and H2 frames DATA with a bulk copy. At 0eb3844, transferring an owned payload array removes another 64 KiB of runtime copies per request. Throughput in that single window fell despite this allocation reduction. At e8a217c, TLS retains complete plaintext buffers and includes record overhead when reading and draining ciphertext. The bulk transport copy also makes previously scalar copies visible to the runtime counter. At fb90ef3 the Native TLS listener reads 16 KiB of plaintext and grants 256 KiB of aggregate H2 receive credit by default. At b106095 the server reserves send credit for up to four DATA frames per write. The counter for outbound flow waits was zero at all these revisions. [Per-change raw windows, including warmup](step-windows.jsonl)

## Supplementary workloads

The JSON worker requested a short document. The upload worker sent 64 KiB in chunks of up to 4 KiB without a fixed request length. The server checked each byte and returned the received byte count. The download handler produced sixteen 4 KiB body frames. The Go probe verified the status, HTTP version and response bytes for every request. At each of 1, 4 and 16 workers, both revisions ran one one-second window per workload and protocol. That gives 36 supplementary windows. Four echo windows and eight warmup windows bring the total to 48 windows, 316,268 successful requests and zero errors.

| Protocol and workload | Baseline req/s at 1 / 4 / 16 workers | Integrated req/s at 1 / 4 / 16 workers |
|---|---:|---:|
| H1 JSON | 5,224 / 20,218 / 55,860 | 5,172 / 21,308 / 57,891 |
| H1 upload | 281 / 974 / 2,340 | 1,828 / 8,128 / 12,751 |
| H1 download | 977 / 3,860 / 10,766 | 981 / 3,944 / 11,047 |
| H2 JSON | 4,775 / 4,497 / 4,506 | 4,798 / 4,496 / 4,497 |
| H2 upload | 894 / 734 / 716 | 996 / 1,223 / 783 |
| H2 download | 802 / 745 / 746 | 831 / 762 / 762 |

The records include p50, p95, p99, process resources and all counters. The early per-request allocation and DATA-write measurements direct the optimizations. Comparison of small differences in these one-second exploratory windows requires a longer paired run. [All window measurements](workload-windows.jsonl)

## Reproduce on macOS

Run from the repository root with `go` available and `OPENSSL_ROOT_DIR` set to the intended OpenSSL 3.x distribution. Record the exact binary versions alongside the resulting directories.

```sh
moon run repo-tools/tools/http_server_profile.mbtx -- 3765516 _build/profile-baseline
moon run repo-tools/tools/http_server_profile.mbtx -- --measure _build/profile-baseline
moon run repo-tools/tools/http_server_profile.mbtx -- 47ff8c2 _build/profile-integrated
moon run repo-tools/tools/http_server_profile.mbtx -- --measure _build/profile-integrated
```

Each build takes an isolated git snapshot, injects the current workload handler, and instruments a temporary copy of the installed Native runtime. Its output directory contains an executable and the resolved SHA. Measurement creates a new `windows` directory, saves each result and verifies that allocation and copy counters advance. For CPU sampling use an ordinary release build from the same SHA. Record the probe JSON while `sample <server-pid> 2 1 -f <output>` is running.
