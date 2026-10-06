///|
/// Opt-in Native provider backed by the public `moonbitlang/async/tls` API.
///
/// This is intentionally restricted to the subset that async@0.22.4 can
/// represent without dropping MoonbitHTTP security options. It is not the
/// default provider and does not replace NativeTlsProvider.
pub struct AsyncStreamTlsProvider(Unit)

///|
pub fn AsyncStreamTlsProvider::new() -> AsyncStreamTlsProvider {
  AsyncStreamTlsProvider(())
}

///|
fn render_async_error(error : Error) -> String {
  "\{Repr(error)}"
}

///|
fn async_tls_supported(
  _options : @transport.TlsOptions,
  _server : Bool,
) -> Bool {
  // async@0.22.4 does not expose the negotiated TLS version, cipher or ALPN.
  // SecureConnection carries those values as security-relevant metadata, so
  // accepting a handshake here would manufacture facts the provider cannot
  // prove. Keep the facade fail-closed until the public async API exposes the
  // complete metadata and credential surface required by TlsProvider.
  false
}

///|
async fn AsyncStreamTlsProvider::client_handshake_impl(
  _self : AsyncStreamTlsProvider,
  connection : @transport.StreamConnection,
  options : @transport.TlsOptions,
) -> Result[@transport.SecureConnection, @transport.TlsError] {
  match options.validate_client() {
    Err(error) => return Err(InvalidOptions(error))
    Ok(_) => ()
  }
  if !async_tls_supported(options, false) {
    return Err(Unsupported)
  }
  let host = match options.server_name {
    Some(value) => value
    None => return Err(InvalidOptions(MissingServerName))
  }
  let io = @transport_native.NativeStreamIo::new(connection)
  let tls_result : Result[@async_tls.Tls, Error] = Ok(
    @async_tls.Tls::client_from_pair(
      io,
      io,
      trust=if options.verify_peer { SystemRoot } else { NoVerification },
      host~,
      sni=true,
    ),
  ) catch {
    error => Err(error)
  }
  let tls = match tls_result {
    Ok(value) => value
    Err(error) => {
      io.close()
      return Err(HandshakeFailed(render_async_error(error)))
    }
  }
  let secure_transport = @transport.StreamConnection::new(
    connection.endpoint(),
    async fn(max_bytes) {
      let result : Result[Bytes?, Error] = Ok(tls.read_some(max_len=max_bytes)) catch {
        error => Err(error)
      }
      match result {
        Ok(value) => Ok(value)
        Err(error) => Err(Failed(Receive, render_async_error(error)))
      }
    },
    async fn(bytes) {
      let result : Result[Unit, Error] = Ok(tls.write(bytes)) catch {
        error => Err(error)
      }
      match result {
        Ok(_) => Ok(())
        Err(error) => Err(Failed(Send, render_async_error(error)))
      }
    },
    fn() { tls.close() },
  )
  Ok(
    @transport.SecureConnection::new(
      secure_transport,
      Tls13,
      "async/tls",
      None,
      Some(host),
      options.verify_peer,
    ),
  )
}

///|
pub impl @transport.TlsProvider for AsyncStreamTlsProvider with fn client_handshake(
  self,
  connection,
  options,
) {
  self.client_handshake_impl(connection, options)
}

///|
pub impl @transport.TlsProvider for AsyncStreamTlsProvider with fn server_handshake(
  _self,
  _connection,
  options,
) {
  match options.validate_server() {
    Err(error) => Err(InvalidOptions(error))
    Ok(_) => Err(Unsupported)
  }
}

///|
pub extend AsyncStreamTlsProvider with @transport.TlsProvider::{
  client_handshake,
  server_handshake,
}
