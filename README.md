# ZSeanYves/MoonbitHTTP

MoonbitHTTP is a streaming HTTP protocol library for MoonBit. Version `0.7.0`
is the alpha line for the v1 architecture and deliberately breaks the 0.6 API;
it is not a production release declaration.

Start with the [documentation index](docs/README.md). The short paths are:

- [getting started](docs/guide/getting-started.md) for the first client or server;
- [package map](docs/concepts/packages.md) for package ownership and stability;
- [architecture](docs/concepts/architecture.md) for dependency direction;
- [current validation](docs/release/current.md) and [release gates](docs/release/gates.md)
  for evidence and unfinished production work.

## Quick start

Native HTTP/1 clients receive every host capability explicitly. A resolver is
used before connecting, a policy authorizes each endpoint, and the TLS provider
is selected by the application:

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/client/native" @client_native,
  "ZSeanYves/MoonbitHTTP/tls/native" @tls_native,
  "ZSeanYves/MoonbitHTTP/transport",
  "ZSeanYves/MoonbitHTTP/transport/native" @transport_native,
}

async fn main {
  let client = @client_native.new_http1_client(
    @transport_native.NativeResolver::new(),
    @transport.AllowAllPolicy::new(),
    @transport_native.NativeClock::new(),
    @tls_native.NativeTlsProvider::new(),
  ).unwrap()
  // Build a @types.Request[Bytes] and call client.send(request) here.
  client.close()
}
```

The Native TLS adapter requires OpenSSL 3; QUIC TLS requires OpenSSL 3.5 or
newer. The portable protocol core builds for Native, Wasm, Wasm-GC and JS.
Native TLS and QUIC evidence is collected separately on Ubuntu, macOS and
Windows. `cmd`, `test_support`, `tools` and `scripts` are development
components, not stable runtime entry points.

## Package families

The repository keeps package boundaries by responsibility. The current paths
remain stable during this documentation and release-governance phase; a later
v1 alpha migration may add category directories after the package map and
generated interfaces are frozen.

| Family | Packages |
| --- | --- |
| Core data | `types`, `body`, `codec` |
| Protocol engines | `http1`, `http2`, `http3`, `quic`, `tls` |
| Runtime contracts | `transport`, `service` |
| Application facades | `client`, `server` |
| Optional policies | `auth`, `cache`, `cookie`, `content_coding`, `auto` |
| Host adapters | `client/native`, `server/native`, `tls/native`, `transport/native`, `uv_adapter` |
| Development | `test_support`, `cmd/*`, `tools`, `scripts` |

See the [package map](docs/concepts/packages.md) for public versus development
stability and target support. Protocol packages do not create sockets; drivers
consume the capability contracts from `transport`.

## Verification

Run Moon commands serially because they share the module build lock. The
canonical validation layers and CI commands live in
[development/testing](docs/development/testing.md). Current test counts,
interoperability artifacts, package digests and open production gates belong in
[release/current](docs/release/current.md), not in this entry page.

## License

Apache License 2.0. See [LICENSE](LICENSE).
