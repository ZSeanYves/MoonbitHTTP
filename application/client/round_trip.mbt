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

///|
/// A buffered response keeps trailing fields separate from the original head.
pub struct BufferedResponse {
  status : Int32
  version : @types.Version
  headers : @types.HeaderMap
  body : Bytes
  trailers : @types.HeaderMap?
}

///|
async fn collect_client_response(
  response : @types.Response[@body.BodyStream],
  limit : Int32,
) -> BufferedResponse {
  let (body, trailers) = @body.collect(response.body, max_bytes=limit)

  {
    status: response.status,
    version: response.version,
    headers: response.headers,
    body,
    trailers,
  }
}
