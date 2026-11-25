# `adapter/native/transport`

[中文](README_zh.md) · [Project README](../../../README.md)

Native only. `TcpConnector` opens connections to numeric endpoints. Its caller checks the network policy before resolving names and connecting to each candidate. UDP socket APIs take the policy directly. `NativeResolver` resolves hostnames in system order and accepts numeric IP literals without DNS. `NativeClock` supplies monotonic and wall-clock time.

In `moon.pkg`

```moonbit
import {
  "moonbitlang/core/async",
  "ZSeanYves/http/adapter/native/transport" @native_transport,
  "ZSeanYves/http/runtime/transport",
} for "test"

supported_targets = "+native"

options(
  "allow-experimental-packages": ["moonbitlang/core/async"],
)
```

Save as `example_test.mbt`.

```moonbit
async test "resolve a numeric loopback address" {
  let resolver = @native_transport.NativeResolver::new()
  let addresses = resolver
    .resolve("127.0.0.1", @transport.ResolveOptions::defaults())
    .unwrap()
  assert_eq(addresses.length(), 1)
}
```
