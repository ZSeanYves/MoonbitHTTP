# `adapter/native/tls`

[English](README.md) · [项目说明](../../../README_zh.md)

仅支持 Native。`NativeTlsProvider` 使用 OpenSSL 3.x 在已有字节流上进行 TLS 握手。QUIC 握手使用 `NativeQuicTlsProvider`，需要 OpenSSL 3.5 或更高的 3.x 版本。握手时通过 `TlsOptions` 传入对端身份、ALPN、信任锚和所需凭据。流式 TLS 提供方的构造参数控制是否使用系统根证书。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/adapter/native/tls" @native_tls,
  "ZSeanYves/http/runtime/transport",
}

supported_targets = "+native"
```

将函数放入调用方包的 `.mbt` 文件中。

```moonbit
pub async fn secure(
  stream : @transport.StreamConnection,
  host : String,
) -> Result[@transport.SecureConnection, @transport.TlsError] {
  let tls = @native_tls.NativeTlsProvider::new()
  tls.client_handshake(
    stream,
    @transport.TlsOptions::defaults().for_server_name(host),
  )
}
```

## 对端验证与关闭

通过 `TlsOptions.revocation_lists` 传入 PEM 格式的 CRL，可用 `require_crl` 要求检查证书链的吊销状态。服务端可通过 `ocsp_response` 附带 DER 格式的 OCSP 响应，客户端可用 `require_ocsp` 要求收到有效响应。适配器在本地验证附带的响应。最后一次写入后调用 `SecureConnection::finish` 发出本端的关闭通知；需要立即释放连接时调用 `close`。
