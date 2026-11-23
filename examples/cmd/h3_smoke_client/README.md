# `examples/cmd/h3_smoke_client`

The native client resolves `localhost` with the native resolver and connects to the pinned aioquic HTTP/3 server on 127.0.0.1:18444. It uses `with_http3_pool` to verify concurrent POST and GET response bytes, origin isolation, peer identity and connection closure. Run `moon run repo-tools/tools/prepare_http3_interop.mbtx` followed by `moon run repo-tools/tools/http3_interoperability.mbtx --reverse` from the repository root.

The optional peer-restart mode runs with a single pool slot. It checks the transport error on two pending requests and verifies that the next request completes after the reference server restarts. See the [interop instructions](../../../docs/development/interop.md#http3-peer-restart).

For sustained requests, the interoperability runner accepts a UDP peer, HTTPS authority, trust anchors, duration and worker count. It checks complete GET and POST responses over one connection. See the [separate-peer instructions](../../../docs/development/interop.md#sustained-requests-to-a-separately-managed-http3-peer).
