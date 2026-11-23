# `examples/cmd/h3_smoke_client`

The native client connects to the pinned aioquic HTTP/3 server on 127.0.0.1:18444. It verifies concurrent POST and GET response bytes, peer identity and scoped connection closure. Run `moon run repo-tools/tools/prepare_http3_interop.mbtx` followed by `moon run repo-tools/tools/http3_interoperability.mbtx --reverse` from the repository root.
