# `examples/cmd/smoke_server`

[中文](README_zh.md) · [Project README](../../../README.md)

A Native loopback server for trying HTTP/1.1 and h2c. Run it from the repository root. The default listener binds `127.0.0.1:18080`, returns a short text body for GET and echoes the incoming body for POST. In a second terminal, use the streaming client or curl.

```sh
moon run examples/cmd/smoke_server --target native

# In a second terminal
curl http://127.0.0.1:18080/
curl --data-binary 'hello' http://127.0.0.1:18080/echo
```

For the buffered interoperability cases, pass `--echo-h1 PORT` or `--echo-h2 PORT CERT KEY` after `--`. The latter serves HTTP/2 over TLS with the supplied PEM files. Both modes limit collected request bodies to 1 MiB.

To send a streaming POST from MoonBit, run the `h1 upload` example against `/echo`. [Streaming client](../streaming_client/README.md)
