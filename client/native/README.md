# `client/native`

> Status: Native adapter
> Scope: explicit resolver, policy, clock and TLS client construction
> Targets: Native only

This adapter is the Native entry point for `client`. It requires all network
capabilities as constructor arguments and performs policy checks before a
socket connect. It does not define portable protocol state.

See [`transport/native`](../../transport/native/) and [`tls/native`](../../tls/native/)
for the injected providers.
