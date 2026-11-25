# `runtime/transport`

[中文](README_zh.md) · [Project README](../../README.md)

Contracts for a stream connector, datagram I/O, DNS, network policy, time, and TLS handshakes. Supply implementations for your host or use the Native adapters. For QUIC, bind the TLS identity to the HTTPS origin even if the datagram peer is a numeric IP address.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/runtime/transport",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "configure QUIC for an HTTPS origin" {
  let options = @transport.TlsOptions::for_quic("example.com")
  assert_eq(options.server_name, Some("example.com"))
  assert_eq(options.alpn, ["h3"])
}
```
