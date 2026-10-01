# Generated local package dependencies

Generated from every repository `moon.pkg` by `tools/check_architecture.mbtx`.
Solid arrows are main imports; dotted arrows are test-only imports, labeled by target.
Architecture boundary checks apply to both. External dependencies are omitted.

```mermaid
flowchart TD
  p_tls["tls"]
  p_auth["auth"]
  p_auto["auto"]
  p_body["body"]
  p_quic["quic"]
  p_cache["cache"]
  p_codec["codec"]
  p_http1["http1"]
  p_http2["http2"]
  p_http3["http3"]
  p_types["types"]
  p_client["client"]
  p_cookie["cookie"]
  p_server["server"]
  p_service["service"]
  p_transport["transport"]
  p_tls_native["tls/native"]
  p_uv_adapter["uv_adapter"]
  p_test_support["test_support"]
  p_client_native["client/native"]
  p_server_native["server/native"]
  p_content_coding["content_coding"]
  p_cmd_smoke_server["cmd/smoke_server"]
  p_transport_native["transport/native"]
  p_cmd_h3_smoke_server["cmd/h3_smoke_server"]
  p_quic --> p_tls
  p_auth --> p_types
  p_auto --> p_types
  p_body --> p_types
  p_http3 --> p_quic
  p_quic --> p_types
  p_cache --> p_types
  p_client --> p_auth
  p_client --> p_body
  p_http1 --> p_codec
  p_http1 --> p_types
  p_http2 --> p_codec
  p_http2 --> p_types
  p_http3 --> p_codec
  p_http3 --> p_types
  p_client --> p_cache
  p_client --> p_http1
  p_client --> p_types
  p_cookie --> p_types
  p_service --> p_auto
  p_service --> p_body
  p_client --> p_cookie
  p_service --> p_http1
  p_service --> p_http2
  p_service --> p_types
  p_tls --> p_transport
  p_client --> p_service
  p_quic --> p_transport
  p_transport --> p_types
  p_client --> p_transport
  p_server --> p_transport
  p_tls_native -. "wbtest" .-> p_tls
  p_tls_native --> p_types
  p_quic -. "test" .-> p_test_support
  p_tls_native -. "wbtest" .-> p_quic
  p_test_support -. "test" .-> p_http1
  p_test_support -. "test" .-> p_types
  p_client_native -. "test" .-> p_types
  p_client -. "test" .-> p_test_support
  p_content_coding --> p_body
  p_server_native --> p_types
  p_client_native --> p_client
  p_content_coding --> p_types
  p_server_native --> p_server
  p_tls_native --> p_transport
  p_client --> p_content_coding
  p_cmd_smoke_server --> p_body
  p_cmd_smoke_server --> p_types
  p_test_support --> p_transport
  p_transport_native --> p_types
  p_client_native --> p_transport
  p_server_native --> p_transport
  p_client_native -. "test" .-> p_tls_native
  p_cmd_h3_smoke_server --> p_quic
  p_cmd_smoke_server --> p_service
  p_cmd_h3_smoke_server --> p_http3
  p_cmd_h3_smoke_server --> p_types
  p_tls_native -. "wbtest" .-> p_test_support
  p_client_native -. "wbtest" .-> p_tls_native
  p_server_native -. "wbtest" .-> p_tls_native
  p_transport_native --> p_transport
  p_client_native --> p_content_coding
  p_cmd_h3_smoke_server --> p_transport
  p_client_native --> p_transport_native
  p_cmd_h3_smoke_server --> p_tls_native
  p_server_native -. "wbtest" .-> p_transport_native
  p_cmd_h3_smoke_server --> p_transport_native
```
