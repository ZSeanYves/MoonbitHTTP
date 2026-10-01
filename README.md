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
  "ZSeanYves/MoonbitHTTP/adapter/native/client" @client_native,
  "ZSeanYves/MoonbitHTTP/adapter/native/tls" @tls_native,
  "ZSeanYves/MoonbitHTTP/runtime/transport",
  "ZSeanYves/MoonbitHTTP/adapter/native/transport" @transport_native,
  "ZSeanYves/MoonbitHTTP/core/types" @types,
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
Windows. `examples/cmd`, `internal/test_support`, `repo-tools/tools` and
`repo-tools/scripts` are development components, not runtime entry points.

## Package families

Package identity is the module name plus the directory containing `moon.pkg`.
These canonical paths define the 0.7.0 alpha API; moving a package changes its
import identity and is a breaking change.

| Family | Packages |
| --- | --- |
| Core data | `core/types`, `core/body`, `core/codec` |
| Protocol engines | `protocol/http1`, `protocol/http2`, `protocol/http3`, `protocol/quic`, `protocol/tls` |
| Runtime contracts | `runtime/transport`, `runtime/service`, `runtime/detection` |
| Application facades | `application/client`, `application/server` |
| Optional policies | `policy/auth`, `policy/cache`, `policy/cookie`, `policy/content_coding` |
| Host adapters | `adapter/native/client`, `adapter/native/server`, `adapter/native/tls`, `adapter/native/transport`, `adapter/uv` |
| Development | `internal/test_support`, `examples/cmd/*`, `repo-tools/tools`, `repo-tools/scripts` |

See the [package map](docs/concepts/packages.md) for public versus development
stability and target support. Protocol packages do not create sockets; drivers
consume the capability contracts from `runtime/transport`.

## Verification

Run Moon commands serially because they share the module build lock. The
canonical validation layers and CI commands live in
[development/testing](docs/development/testing.md). Current test counts,
interoperability artifacts, package digests and open production gates belong in
[release/current](docs/release/current.md), not in this entry page.

## License

Apache License 2.0. See [LICENSE](LICENSE).
