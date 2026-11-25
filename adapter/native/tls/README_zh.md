# `adapter/native/tls`

[English](README.md) · [项目说明](../../../README_zh.md)

仅支持 Native。`NativeTlsProvider` 使用 OpenSSL 3.x 在已有字节流上进行 TLS 握手。QUIC 握手使用 `NativeQuicTlsProvider`，需要 OpenSSL 3.5 或更高的 3.x 版本。握手时通过 `TlsOptions` 传入对端身份、ALPN、信任锚和所需凭据。流式 TLS 提供方的构造参数控制是否启用 OpenSSL 默认信任路径。

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

## 信任根来源

启用对端验证后，显式传入的非空 PEM `trust_anchors` 将替换 OpenSSL 默认根。`trust_anchors=None` 且 `allow_system_roots=true` 时，提供方调用进程实际加载的 OpenSSL 的 `SSL_CTX_set_default_verify_paths`。根文件、哈希目录和平台信任库集成取决于该发行版与运行配置。可在启动进程前将 `SSL_CERT_FILE` 指向 PEM 包，或将 `SSL_CERT_DIR` 设为 OpenSSL 哈希证书目录。每个连接均建立新的验证上下文。

Linux 使用所选发行版或固定构建的配置。macOS 查看所选 Homebrew OpenSSL 路径，Windows 查看 `OPENSSL_ROOT_DIR` 对应的发行版。需要在各平台信任企业 CA 时，可显式传入 PEM。仅导入系统 Keychain 或 Windows 证书库能否生效，取决于 OpenSSL 分发。可使用同一分发的 `openssl version -a` 查看构建默认值。

## 对端验证与关闭

通过 `TlsOptions.revocation_lists` 传入 PEM 格式的 CRL，可用 `require_crl` 要求检查证书链的吊销状态。服务端可通过 `ocsp_response` 附带 DER 格式的 OCSP 响应，客户端可用 `require_ocsp` 要求收到有效响应。适配器在本地验证附带的响应。最后一次写入后调用 `SecureConnection::finish` 发出本端的关闭通知；需要立即释放连接时调用 `close`。
