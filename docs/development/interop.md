# Interoperability

> Status: canonical
> Scope: independent HTTP/1.1, HTTP/2, h2c and HTTP/3 checks for 0.7.0
> Source: working-tree (governed by Git)
> Last reviewed: 2026-11-23

Interoperability checks exercise the built library through real sockets and an
independent client. They complement codec and state-machine tests; they do not
replace conformance review, long-duration pressure or performance thresholds.

## HTTP/3 peer restart

Build the independent quic-go reference server with Go 1.24 or newer. Run the
following commands from the module root with the native HTTP/3 toolchain:

```sh
mkdir -p _build
go -C repo-tools/tools/quic_go_reset_reference build -mod=readonly -o "$PWD/_build/quic-go-reset-reference" .
moon run repo-tools/tools/http3_interoperability.mbtx --peer-restart "$PWD/_build/quic-go-reset-reference"
```

The runner waits for a pending request, restarts the reference process on the
same loopback port with the same temporary reset key and sends another request
on the old connection. Both requests must report a stateless reset. A fresh
request must succeed in the same one-slot pool. The runner records both server
logs, the client result, the
source revision and binary hashes in `_build/evidence/http3-interoperability/`.
Only the new readiness request should reach the restarted application.

## TCP protocols

`repo-tools/tools/interoperability.mbtx` requires `curl`, `wget` and `nghttp`. It builds
the Native smoke server, rejects a pre-existing listener on the test port,
then checks:

- HTTP/1.1 GET and POST with both `curl` and `wget`.
- HTTP/2 prior knowledge and h2c upgrade with `nghttp`.

Each case verifies status, headers and body. The runner records the selected
server binary, Git revision, tool versions, commands, process exits and logs
under `_build/evidence/interoperability/`. Missing clients are a preflight
failure, not a passing subset. A caller-supplied `--server` path is labeled in
the report and cannot establish that the binary came from the current source.

Run it from the module root with:

```text
moon run repo-tools/tools/interoperability.mbtx
```

## HTTP/3 and QUIC

Prepare the pinned independent client and run the bounded checks with:

```text
moon run repo-tools/tools/prepare_http3_interop.mbtx
moon run repo-tools/tools/http3_interoperability.mbtx
```

The HTTP/3 runner uses the Native smoke server, an aioquic client and OpenSSL
3.5 or newer for the QUIC TLS callback provider. Positive cases cover verified
GET and POST, authenticated requests, key update and concurrent request
streams. The built-in server starts POST requests with a 256-byte stream window
and a 1024-byte connection window. The runner verifies a 4096-byte echo.
In the same client qlog it checks both window updates, a destination CID
change during the upload, request-body bytes sent on the replacement CID,
retirement of the initial CID and the server's next spare advertisement.
One aioquic process also sends 256 requests over a single connection with an
initial allowance of eight bidirectional streams. The runner checks each response
and counts the connection traces. The duration window uses fresh connections
for successive requests. Negative cases must use an explicitly untrusted or mismatched
credential and must assert a failed verification outcome.

The server fixture details and its non-deployment limits are documented in
[`examples/cmd/h3_smoke_server`](../../examples/cmd/h3_smoke_server/README.md); Native TLS
runtime requirements are documented in [`adapter/native/tls`](../../adapter/native/tls/README.md).

Impaired mode inserts controlled loss, delay and reordering in both directions
and preserves encrypted datagram bytes. It must observe the configured packet
events, drain all delay queues at shutdown, and retain qlog, counters,
endpoints, commands, versions, process status and binary hashes. Use the
duration and concurrency flags to define a bounded experiment; do not describe
that loopback experiment as WAN behavior or production capacity.

```text
moon run repo-tools/tools/http3_interoperability.mbtx \
  --reverse --impair --concurrent-requests 8 --duration-seconds 300
```

With `--reverse`, the runner also starts the pinned aioquic server and its unmodified ASGI application on 127.0.0.1:18444. The native MoonBit client verifies a concurrent 4 KiB POST echo and 128 KiB download on one authenticated connection, then checks that OpenSSL rejects a mismatched hostname before the application callback runs. The reverse leg uses direct loopback. Its result includes the client binary and independent server/application hashes.

The independent client revision and dependency version are part of the
evidence. Changing either requires a new report. Native QUIC fixture tests
prove the provider/driver boundary and recovery actions, but only independent
wire interoperability proves interaction with another implementation.

## Sustained requests to a separately managed HTTP/3 peer

The native client holds one authenticated QUIC connection for the entire
measurement. Each worker alternates a binary 4 KiB POST to `/echo` and a GET
to `/4096`. The client checks HTTP/3, status 200 and all 4 KiB of each
response. Timing starts after the handshake and continues until every worker
finishes its last pair. A pair has a 30-second timeout. A lost connection
fails the run.

On the server machine, prepare the pinned aioquic environment as above. Use
a certificate for the chosen HTTPS name and bind an address reachable from the
client. For example, with the address, certificate and key paths in the shell
variables below:

```sh
_build/interop-aioquic/venv/bin/python _build/interop-aioquic/upstream/examples/http3_server.py \
  --host "$SERVER_IP" --port 18444 --certificate "$CERT_PEM" --private-key "$KEY_PEM" \
  >peer.log 2>&1
```

On the client machine, supply the numeric UDP address (IPv6 uses brackets),
the HTTPS authority, its trust anchors, the duration in seconds (1–3600) and
the number of workers (1–32). For a one-hour run with eight workers:

```sh
moon run repo-tools/tools/http3_interoperability.mbtx \
  --peer-soak "$SERVER_IP:18444" "$TLS_NAME:18444" "$CA_PEM" 3600 8 --impair
```

The optional `--impair` applies the same bidirectional loss, delay and reorder
profile used by the forward fixture. The local relay forwards to the supplied
UDP address. TLS and the HTTP authority still use the supplied peer name.
Complete packet counters accompany a sample of the first 4,096 relay events.
Without the flag, datagrams go directly to the peer.

The client evidence directory includes the revision, worktree status, client
hostname, binary and trust-file hashes, command, exit status and completed
pairs. After an established connection unwinds, the client also leaves its
completed-pair count in `client.stdout` on failure. Keep the independent
server's log, machine identity and aioquic
revision beside the result. After the peer log is closed, reconcile an isolated
run from either machine:

```sh
moon run repo-tools/tools/verify_http3_peer_soak.mbtx "$RUN_DIR/result.json" peer.log
```

The verifier checks one negotiated H3 connection, the exact method counts and
the peer's received close code. It emits both input hashes. Record the
placement of both machines when evaluating the physical-host release gate.

## Failure classification

Record preflight, implementation, peer, timeout and environment failures
separately. Preserve stdout, stderr and partial packet logs on every failure.
Do not turn a missing executable, unavailable OpenSSL callback API or skipped
client into a successful result. Link completed runs from
[current evidence](../release/current.md), and track unresolved scope in
[release gates](../release/gates.md).
