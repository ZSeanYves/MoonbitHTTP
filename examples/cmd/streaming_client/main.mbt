///|
async fn exchange(
  send : async (@types.Request[@body.BodyStream]) -> @types.Response[
    @body.BodyStream,
  ],
  uri : @types.Uri,
  version : @types.Version,
  upload : Bool,
) -> Unit {
  let producer = if upload {
    @body.BodyStream::from_pull(async fn() {
      @async.sleep(20)
      Some(Data(b"sample\n"))
    })
  } else {
    @body.BodyStream::from_pull(() => None, size_hint=@body.SizeHint::exact(0))
  }
  defer producer.cancel(@body.BodyError::Cancelled)
  let request : @types.Request[@body.BodyStream] = {
    http_method: if upload {
      Post
    } else {
      Get
    },
    version,
    uri,
    headers: @types.HeaderMap::new(),
    body: producer,
  }
  @async.with_timeout(if upload { 1000 } else { 30000 }, async fn() {
    let response = send(request)
    defer response.body.cancel(@body.BodyError::Cancelled)
    let (bytes, _) = @body.collect(response.body, max_bytes=1024 * 1024)
    println("HTTP \{response.status}, \{bytes.length()} response bytes")
  }) catch {
    @async.TimeoutError if upload =>
      println("Upload cancelled at its one-second deadline")
    err => raise err
  }
}

///|
async fn main {
  let args = @env.args()
  guard args.length() == 4 || args.length() == 5 else {
    fail("usage: streaming_client h1|h2|h3 get|upload ABSOLUTE_URI [CA_PEM]")
  }
  let upload = match args[2] {
    "get" => false
    "upload" => true
    _ => fail("expected get or upload")
  }
  let uri = @types.Uri::parse(args[3]).unwrap_or_error()
  let roots = if args.length() == 5 {
    Some(@fs.read_binary(args[4]))
  } else {
    None
  }
  let resolver = @native_transport.NativeResolver::new()
  let policy = @transport.AllowAllPolicy::new()
  let clock = @native_transport.NativeClock::new()
  let tls = @native_tls.NativeTlsProvider::new()
  match args[1] {
    "h1" => {
      let pool = @client.Http1PooledRoundTripper::from_capabilities(
        @native_transport.TcpConnector::new(),
        resolver,
        tls,
        policy,
        clock,
        origin_tls={
          ..@transport.TlsOptions::defaults(),
          alpn: ["http/1.1"],
          trust_anchors: roots,
        },
      ).unwrap_or_error()
      defer pool.close()
      exchange(
        request => pool.execute_body(request).unwrap_or_error(),
        uri,
        Http11,
        upload,
      )
    }
    "h2" => {
      let options = @client.Http2PoolOptions::defaults()
      @native_client.with_http2_client(
        resolver,
        policy,
        clock,
        tls,
        pool => {
          exchange(
            request => pool.execute_body(request).unwrap_or_error(),
            uri,
            Http2,
            upload,
          )
        },
        options={ ..options, tls: { ..options.tls, trust_anchors: roots, }, },
      )
    }
    "h3" =>
      @native_client.with_http3_pool(
        resolver,
        policy,
        pool => exchange(request => pool.send(request), uri, Http3, upload),
        tls={ ..@transport.TlsOptions::quic_defaults(), trust_anchors: roots, },
      )
    _ => fail("expected h1, h2 or h3")
  }
}
