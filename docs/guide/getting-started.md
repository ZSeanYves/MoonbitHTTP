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
  "ZSeanYves/MoonbitHTTP/client/native" @client_native,
  "ZSeanYves/MoonbitHTTP/tls/native" @tls_native,
  "ZSeanYves/MoonbitHTTP/transport",
  "ZSeanYves/MoonbitHTTP/transport/native" @transport_native,
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
