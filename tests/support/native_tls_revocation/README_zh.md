# `tests/support/native_tls_revocation`

[English](README.md) · [项目说明](../../../README_zh.md)

Native 测试使用的签名 OCSP 响应和证书吊销列表生成工具。TLS 集成测试向 `test_ocsp` 和 `test_crl` 传入测试证书和签名密钥，再将生成的数据传给 Native 提供方。在仓库根目录运行该测试包。

```sh
moon test tests/integration/native_tls --target native
```
