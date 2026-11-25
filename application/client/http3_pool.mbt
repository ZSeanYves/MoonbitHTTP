///|
/// Scoped HTTP/3 executor. Connections are keyed by the complete HTTPS origin.
pub struct Http3Client {
  priv pool : OriginPool[@service.Http3ClientConnection]
  priv now_millis : () -> Int64
  priv pinned_host : String?
}

///|
/// Supply a verified connection scope which calls ready once and forwards
/// service state notifications to changed. Native applications can use
/// adapter/native/client.with_http3_pool with a resolver and network policy.
pub async fn[X] with_http3_pool(
  open : async (
    ClientEndpoint,
    async (@service.Http3ClientConnection) -> Unit,
    () -> Unit,
  ) -> Unit,
  run : async (Http3Client) -> X,
  max_connections~ : Int32 = 32,
  server_name~ : String? = None,
  now_millis~ : () -> Int64 = @async.now,
) -> X {
  let pinned_host = server_name.map(name => {
    @types.Endpoint::new("https", name, 443).unwrap_or_error().host()
  })
  with_origin_pool(
    "HTTP/3",
    max_connections,
    async fn(endpoint, ready, changed) {
      open(endpoint, ready, changed)
      Ok(())
    },
    @service.Http3ClientConnection::accepts_requests,
    @service.Http3ClientConnection::is_idle,
    pool => run({ pool, pinned_host, now_millis, }),
  )
}

///|
/// Send once. Consume or cancel the streaming response within this scope.
pub async fn[B : @body.Body] Http3Client::send(
  self : Http3Client,
  request : @types.Request[B],
  timeouts? : ClientTimeouts,
) -> @types.Response[@body.BodyStream] {
  if timeouts is Some(limits) && limits.validate() is Err(error) {
    request.body.cancel(error)
    raise error
  }
  let timeout = phase_timeouts(timeouts, self.now_millis)
  self.pool
  .exchange(request, (client, request) => client.send(request, timeout?), validate_origin=endpoint => {
    if !endpoint.secure ||
      (self.pinned_host is Some(host) && host != endpoint.transport.host()) {
      raise @service.Http3ClientError::InvalidOrigin
    }
  })
  .unwrap_or_error()
}

///|
pub fn Http3Client::close(self : Http3Client) -> Unit {
  self.pool.close()
}

///|
/// Count opening, usable and draining connections against the same bound.
pub fn Http3Client::connection_count(self : Http3Client) -> Int32 {
  self.pool.sessions.length()
}
