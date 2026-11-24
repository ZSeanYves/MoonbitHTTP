# `examples/cmd/h3_smoke_server`

[中文](README_zh.md) · [Project README](../../../README.md)

A Native HTTP/3 example and interoperability fixture. It listens on `127.0.0.1:18443` over UDP, returns a text body for GET and echoes a POST body while asking the peer to rotate its destination connection ID. The example loads the repository’s loopback certificate and key. Run from the repository root with OpenSSL 3.5 or later in the 3.x series.

```sh
moon run examples/cmd/h3_smoke_server --target native

# In a second terminal
moon run examples/cmd/streaming_client --target native -- h3 get https://localhost:18443/ tests/fixtures/tls/localhost.cert.pem
```

Pass `-- --once` after `--target native` to begin draining when the first handler starts. The handler can finish its exchange before the server exits.
