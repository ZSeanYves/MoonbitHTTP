# `examples/cmd/streaming_client`

[中文](README_zh.md) · [Project README](../../../README.md)

A Native client example for streaming HTTP/1.1, HTTP/2 and HTTP/3. Run these commands from the repository root against the [local example server](../smoke_server/README.md). Each response prints its status and byte count.

```sh
moon run examples/cmd/streaming_client --target native -- h1 get http://127.0.0.1:18080/
moon run examples/cmd/streaming_client --target native -- h1 upload http://127.0.0.1:18080/echo
```

Arguments are `h1|h2|h3 get|upload ABSOLUTE_URI [CA_PEM]`. Select a protocol the destination serves. Pass a trust anchor file for a private HTTPS origin. GET has a 30-second deadline. Upload produces chunks until the one-second deadline or an earlier response completes. The response collection limit is 1 MiB.

For the `h3` mode, start the UDP example and pass its fixture CA to the client. [HTTP/3 server and matching command](../h3_smoke_server/README.md)
