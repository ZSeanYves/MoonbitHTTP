///|
#warnings("-alert_internal")
priv struct NativeStreamIo {
  /// Reader/Writer view over the capability-bound stream used by the host TLS
  /// implementation. Transport errors are raised only inside this adapter and
  /// are converted back to TlsError at the handshake boundary.
  reader_buffer : @aio.ReaderBuffer
  connection : @transport.StreamConnection
  observer : NativeTlsObserver
}

///|
#warnings("-alert_internal")
fn NativeStreamIo::new(
  connection : @transport.StreamConnection,
  observer : NativeTlsObserver,
) -> NativeStreamIo {
  { reader_buffer: @aio.ReaderBuffer::new(), connection, observer, }
}

///|
#warnings("-alert_internal")
impl @aio.Reader for NativeStreamIo with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
#warnings("-alert_internal")
impl @aio.Reader for NativeStreamIo with fn _direct_read(
  self,
  destination,
  offset~,
  max_len~,
) {
  let result = match self.connection.read(max_len) {
    Ok(value) => value
    Err(error) => raise error
  }
  match result {
    None => 0
    Some(bytes) => {
      self.observer.feed(bytes)
      let count = bytes.length().min(max_len)
      for index in 0..<count {
        destination[offset + index] = bytes[index]
      }
      count
    }
  }
}

///|
#warnings("-alert_internal")
impl @aio.Writer for NativeStreamIo with fn write_once(
  self,
  source,
  offset~,
  len~,
) {
  let bytes = source[offset:offset + len].to_owned()
  match self.connection.write(bytes) {
    Ok(_) => ()
    Err(error) => raise error
  }
  len
}

///|
pub struct NativeTlsProvider {
  allow_system_roots : Bool
}

///|
pub fn NativeTlsProvider::new(
  allow_system_roots? : Bool = true,
) -> NativeTlsProvider {
  { allow_system_roots, }
}

///|
fn native_tls_error(_error : Error) -> @tls.TlsError {
  HandshakeFailed("native TLS handshake failed")
}

///|
/// The host TLS API used by this adapter does not expose ALPN offer
/// configuration. Accepting a broader option list would claim protocol
/// negotiation that was never sent on the wire, so fail closed at the
/// capability boundary.
fn native_tls_alpn_supported(options : @tls.TlsOptions) -> Bool {
  options.alpn.length() == 1 && options.alpn[0] == "http/1.1"
}

///|
pub impl @tls.TlsProvider for NativeTlsProvider with fn client_handshake(
  self,
  connection,
  options,
) {
  @async.pause()
  match options.validate_client() {
    Ok(_) => ()
    Err(error) => return Err(InvalidOptions(error))
  }
  if !native_tls_alpn_supported(options) {
    return Err(Unsupported)
  }
  if options.trust_anchors is Some(_) ||
    options.client_certificate is Some(_) ||
    options.client_private_key is Some(_) {
    return Err(Unsupported)
  }
  if !self.allow_system_roots && options.verify_peer {
    return Err(Unsupported)
  }
  let host = match options.server_name {
    Some(value) => value
    None => return Err(InvalidOptions(MissingServerName))
  }
  let trust : @atls.TrustedRoot = if options.verify_peer {
    SystemRoot
  } else {
    NoVerification
  }
  let observer = NativeTlsObserver::new()
  let io = NativeStreamIo::new(connection, observer)
  let tls = @atls.Tls::client(io, host~, trust~) catch {
    error => {
      connection.close()
      return Err(native_tls_error(error))
    }
  }
  let metadata = match observer.result() {
    Ok(value) => value
    Err(error) => {
      tls.close()
      connection.close()
      return Err(HandshakeFailed(error))
    }
  }
  if !native_tls_version_allowed(options, metadata.version) {
    tls.close()
    connection.close()
    return Err(HandshakeFailed("negotiated TLS version violates policy"))
  }
  match metadata.alpn {
    Some(protocol) if !options.alpn.contains(protocol) => {
      tls.close()
      connection.close()
      return Err(HandshakeFailed("server selected an unoffered ALPN protocol"))
    }
    None if !options.alpn.contains("http/1.1") => {
      tls.close()
      connection.close()
      return Err(HandshakeFailed("server did not negotiate required ALPN"))
    }
    _ => ()
  }
  let transport = @transport.StreamConnection::new(
    connection.endpoint(),
    async fn(max_bytes) {
      let result = tls.read_some(max_len=max_bytes) catch {
        _ => return Err(Failed(Receive, "native TLS read failed"))
      }
      Ok(result)
    },
    async fn(bytes) {
      tls.write(bytes) catch {
        _ => return Err(Failed(Send, "native TLS write failed"))
      }
      Ok(())
    },
    fn() {
      tls.close()
      connection.close()
    },
  )
  Ok(
    @tls.SecureConnection::new(
      transport,
      metadata.version,
      metadata.cipher_suite,
      metadata.alpn,
      Some(host),
      options.verify_peer,
    ),
  )
}

///|
pub impl @tls.TlsProvider for NativeTlsProvider with fn server_handshake(
  _self,
  _connection,
  options,
) {
  match options.validate_server() {
    Ok(_) => Err(Unsupported)
    Err(error) => Err(InvalidOptions(error))
  }
}
