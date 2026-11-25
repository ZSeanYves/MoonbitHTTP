///|
async fn exchange(
  client : @client.Client,
  uri : @types.Uri,
  upload : Bool,
) -> Unit {
  let body = if upload {
    @client.Upload::once(
      @body.BodyStream::from_pull(async fn() {
        @async.sleep(20)
        Some(Data(b"sample\n"))
      }),
    )
  } else {
    @client.Upload::bytes(b"")
  }
  let request = client.request(if upload { Post } else { Get }, uri, body)
  @async.with_timeout(if upload { 1000 } else { 30000 }, async fn() {
    let response = client.send(request)
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
  let (version, tls) = match args[1] {
    "h1" => (@types.Version::Http11, @transport.TlsOptions::defaults())
    "h2" => (Http2, @transport.TlsOptions::defaults())
    "h3" => (Http3, @transport.TlsOptions::quic_defaults())
    _ => fail("expected h1, h2 or h3")
  }
  @native_client.with_client(
    client => exchange(client, uri, upload),
    version~,
    policy=@transport.AllowAllPolicy::new(),
    tls={ ..tls, trust_anchors: roots, },
  )
}
