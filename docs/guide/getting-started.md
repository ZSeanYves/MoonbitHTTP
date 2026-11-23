# Getting started

> Status: canonical
> Scope: first use of MoonbitHTTP 0.7.0
> Source: working-tree (governed by Git)
> Last reviewed: 2026-10-01

MoonbitHTTP exposes protocol behavior through explicit capabilities. A Native
client receives its resolver, network policy, clock and TLS provider from the
caller; the library does not silently perform hostname resolution or create a
socket before policy evaluation.

The Native constructor accepts the capabilities directly:

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/adapter/native/client" @client_native,
  "ZSeanYves/MoonbitHTTP/adapter/native/tls" @tls_native,
  "ZSeanYves/MoonbitHTTP/runtime/transport",
  "ZSeanYves/MoonbitHTTP/adapter/native/transport" @transport_native,
}

let client = @client_native.new_http1_client(
  @transport_native.NativeResolver::new(),
  @transport.AllowAllPolicy::new(),
  @transport_native.NativeClock::new(),
  @tls_native.NativeTlsProvider::new(),
).unwrap()
client.close()
```

Use the package README for the target's current entry points and run the
smallest target check before adding application code:

```sh
moon check --target native
moon test --target native
```

For browser or Wasm targets, select the corresponding `--target` and inject a
transport implementation that matches that runtime. Protocol packages can be
used directly for codec and state-machine tests; application packages should
own connection policy and lifecycle.

Before relying on a feature, read [Current validation facts](../release/current.md)
and [Release gates](../release/gates.md). Passing a local unit test does not
prove certificate interoperability or long-duration network behavior.

## Streaming GET and cancellable upload

The checkout includes a Native example that selects a client pool and uses the
same request body, response reader and timeout on all three protocols.
A GET reads up to 1 MiB. Upload mode emits a chunk every 20 ms and cancels the
exchange after one second. The response and producer are released on every exit.

Start one fixture in a terminal at the repository root.

```sh
moon run examples/cmd/smoke_server --target native -- --echo-h1 18080
# Or start the HTTP/2 TLS fixture
moon run examples/cmd/smoke_server --target native -- --echo-h2 18446 adapter/native/tls/testdata/localhost.cert.pem adapter/native/tls/testdata/localhost.key.pem
# Or start the HTTP/3 fixture
moon run examples/cmd/h3_smoke_server --target native
```

In another terminal run the matching command. Replace `get` with `upload` to
exercise cancellation. The PEM argument trusts the local fixture certificate
while keeping hostname verification enabled.

```sh
moon run examples/cmd/streaming_client --target native -- h1 get http://127.0.0.1:18080/
moon run examples/cmd/streaming_client --target native -- h2 get https://localhost:18446/ adapter/native/tls/testdata/localhost.cert.pem
moon run examples/cmd/streaming_client --target native -- h3 get https://localhost:18443/ adapter/native/tls/testdata/localhost.cert.pem
```

The example source is in `examples/cmd/streaming_client/main.mbt` in the repository.
