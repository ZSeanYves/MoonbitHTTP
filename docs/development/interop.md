# Interoperability

> Status: canonical
> Scope: independent HTTP/1.1, HTTP/2, h2c and HTTP/3 checks for 0.7.0
> Source: working-tree (governed by Git)
> Last reviewed: 2026-10-01

Interoperability checks exercise the built library through real sockets and an
independent client. They complement codec and state-machine tests; they do not
replace conformance review, long-duration pressure or performance thresholds.

## TCP protocols

`tools/interoperability.mbtx` requires `curl`, `wget` and `nghttp`. It builds
the Native smoke server, rejects a pre-existing listener on the test port,
then checks:

- HTTP/1.1 GET and POST with `curl`;
- HTTP/2 prior knowledge with `nghttp`;
- h2c upgrade with `curl`.

Each case verifies status, headers and body. The runner records the selected
server binary, Git revision, tool versions, commands, process exits and logs
under `_build/evidence/interoperability/`. Missing clients are a preflight
failure, not a passing subset. A caller-supplied `--server` path is labeled in
the report and cannot establish that the binary came from the current source.

Run it from the module root with:

```text
moon run tools/interoperability.mbtx
```

## HTTP/3 and QUIC

Prepare the pinned independent client and run the bounded checks with:

```text
moon run tools/prepare_http3_interop.mbtx
moon run tools/http3_interoperability.mbtx
```

The HTTP/3 runner uses the Native smoke server, an aioquic client and OpenSSL
3.5 or newer for the QUIC TLS callback provider. Positive cases cover verified
GET and POST, authenticated requests, key update and concurrent request
streams. Negative cases must use an explicitly untrusted or mismatched
credential and must assert a failed verification outcome.

The server fixture details and its non-deployment limits are documented in
[`cmd/h3_smoke_server`](../../cmd/h3_smoke_server/README.md); Native TLS
runtime requirements are documented in [`tls/native`](../../tls/native/README.md).

Impaired mode inserts controlled loss, delay and reordering in both directions
and preserves encrypted datagram bytes. It must observe the configured packet
events, drain all delay queues at shutdown, and retain qlog, counters,
endpoints, commands, versions, process status and binary hashes. Use the
duration and concurrency flags to define a bounded experiment; do not describe
that loopback experiment as WAN behavior or production capacity.

```text
moon run tools/http3_interoperability.mbtx \
  --impair --concurrent-requests 8 --duration-seconds 300
```

The independent client revision and dependency version are part of the
evidence. Changing either requires a new report. Native QUIC fixture tests
prove the provider/driver boundary and recovery actions, but only independent
wire interoperability proves interaction with another implementation.

## Failure classification

Record preflight, implementation, peer, timeout and environment failures
separately. Preserve stdout, stderr and partial packet logs on every failure.
Do not turn a missing executable, unavailable OpenSSL callback API or skipped
client into a successful result. Link completed runs from
[current evidence](../release/current.md), and track unresolved scope in
[release gates](../release/gates.md).
