# HTTP/3 interoperability server

This bounded loopback fixture binds UDP `127.0.0.1:18443`. It combines the
library's policy-aware UDP capability, OpenSSL QUIC TLS provider, QUIC packet
driver and HTTP/3 driver. GET returns a fixed body; POST echoes up to 64 KiB.
The three HTTP/3 critical streams use QUIC's normal stream allocation and flow
control. No protocol state machine is duplicated in this executable.

From the repository root:

```text
moon run tools/prepare_http3_interop.mbtx
moon run tools/http3_interoperability.mbtx
```

The preparation command creates an isolated virtual environment and installs
`tools/http3-requirements.txt`. The client is the unmodified aioquic 1.3.0
upstream example at commit `cb103537126bbcc58752fd5bc7c8ac88bf552c01`.
The runner requires OpenSSL 3.5+ for the server; macOS uses Homebrew `openssl@3`,
and Linux CI builds the checksum-pinned 3.5 LTS runtime in `_build/ci-openssl`.

The runner builds the server, checks the port is free, starts it, and tests
verified GET, POST echo, client-initiated key update and rejection of an
untrusted CA. `moon run tools/http3_interoperability.mbtx --long-requests 24`
adds a repeated authenticated request window. It compares the entire response
headers and body, captures qlog,
stdout/stderr, commands, dependency versions, Git revisions and executable
SHA-256 under `_build/evidence/http3-interoperability/`, then stops the server.
Options `--server`, `--python` and `--client` accept explicit existing paths;
the pinned upstream revision and aioquic version remain mandatory.

The checked-in localhost key is a public test fixture and is unsuitable for
deployment. This smoke server caps connections and bodies, reclaims idle or
terminal connections, and polls QUIC recovery while the socket is live; it is
not a general-purpose service acceptor or a multi-hour UDP pressure benchmark.
