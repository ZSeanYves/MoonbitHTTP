# `tests/support/native_tls_revocation`

[中文](README_zh.md) · [Project README](../../../README.md)

Native test fixture builders for signed OCSP responses and certificate revocation lists. The TLS integration suite supplies fixture certificates and signing keys to `test_ocsp` and `test_crl` and passes the resulting bytes to the Native provider. Run the suite from the repository root.

```sh
moon test tests/integration/native_tls --target native
```
