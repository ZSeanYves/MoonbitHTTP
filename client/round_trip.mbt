///|
/// A byte-oriented executor boundary for hosts that already own a protocol
/// driver. The policy client never opens sockets itself; the executor remains
/// responsible for transport/TLS capability injection.
pub(open) trait ByteRoundTripper {
  async fn execute(Self, @types.Request[Bytes]) -> Result[
    @types.Response[Bytes],
    ClientError,
  ]
}

///|
/// A response-streaming executor. The response body owns the underlying
/// lease until it reaches EOF/trailers or is explicitly cancelled.
pub(open) trait StreamingRoundTripper {
  async fn execute_stream(Self, @types.Request[Bytes]) -> Result[
    @types.Response[@body.BodyStream],
    ClientError,
  ]
}

///|
pub struct ClosureRoundTripper {
  execute_fn : async (@types.Request[Bytes]) -> Result[
    @types.Response[Bytes],
    ClientError,
  ]
}

///|
pub fn ClosureRoundTripper::new(
  execute_fn : async (@types.Request[Bytes]) -> Result[
    @types.Response[Bytes],
    ClientError,
  ],
) -> ClosureRoundTripper {
  { execute_fn, }
}

///|
pub impl ByteRoundTripper for ClosureRoundTripper with fn execute(self, request) {
  (self.execute_fn)(request)
}

///|
pub fn response_from_cache(
  hit : @cache.CacheHit,
  request_method : @types.Method,
) -> @types.Response[Bytes] {
  let cached = hit.response()
  {
    status: cached.status,
    version: cached.version,
    headers: cached.headers,
    body: if request_method == Head {
      b""
    } else {
      hit.body()
    },
  }
}
