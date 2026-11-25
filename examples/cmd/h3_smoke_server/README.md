# `examples/cmd/h3_smoke_server`

[中文](README_zh.md) · [Project README](../../../README.md)

A Native HTTP/3 example and interoperability fixture. It listens on `127.0.0.1:18443` over UDP, returns a text body for GET and echoes a POST body while asking the peer to rotate its destination connection ID. The example loads the repository’s loopback certificate and key. Run from the repository root with OpenSSL 3.5 or later in the 3.x series.

```sh
moon run examples/cmd/h3_smoke_server --target native

# In a second terminal
moon run examples/cmd/streaming_client --target native -- h3 get https://localhost:18443/ tests/fixtures/tls/localhost.cert.pem
```

Pass `-- --once` after `--target native` to begin draining when the first handler starts. The handler can finish its exchange before the server exits.

The Native capacity probe runs on macOS and Linux with Go. It opens 0, 100 and 1,000 idle QUIC connections alongside one measured connection on the same loopback listener. Each size has a five-second quiet window, then a five-second window with a GET every 20 ms. The quiet window includes the two boundary snapshots. A separate GET measures completion after dropping server datagrams for 35 ms. Run from the repository root with a soft file-descriptor limit above 1,001.

```sh
moon run repo-tools/tools/http3_idle_capacity.mbtx -- --baseline
moon run repo-tools/tools/http3_idle_capacity.mbtx
```

Each run writes the server and probe hashes, poll counts, process CPU, RSS, OS-specific wakeup counter, latency samples and recovery time under `_build/evidence/performance/h3-idle`. The baseline command checks out `3765516`, applies the counting-only patch to its original 25 ms loop, and builds the same server fixture.
