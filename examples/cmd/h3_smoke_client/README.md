# `examples/cmd/h3_smoke_client`

[中文](README_zh.md) · [Project README](../../../README.md)

A Native interoperability client for the pinned aioquic server. The runner starts the peer on UDP port 18444. The client verifies the contents of concurrent GET and POST responses, a foreign-origin rejection and a certificate hostname mismatch. Run from the repository root with Python and OpenSSL 3.5 or later in the 3.x series.

```sh
moon run repo-tools/tools/prepare_http3_interop.mbtx
moon run repo-tools/tools/http3_interoperability.mbtx --reverse
```

The runner also accepts `--peer-restart PATH_TO_QUIC_GO_SERVER` to check recovery after a server restart, or `--peer-soak UDP_ADDRESS HTTPS_AUTHORITY CA_FILE SECONDS WORKERS` for a separately deployed peer.

In `--peer-soak` mode the workers reuse one authenticated connection. Add `--mixed` to interleave short and large exchanges on it.
