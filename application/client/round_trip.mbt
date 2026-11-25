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
async fn collect_client_response(
  response : @types.Response[@body.BodyStream],
  limit : Int32,
) -> @types.Response[Bytes] {
  let (body, trailers) = @body.collect(response.body, max_bytes=limit)
  match trailers {
    Some(values) =>
      for field in values.fields() {
        response.headers.append(field.name, field.value)
      }
    None => ()
  }
  {
    status: response.status,
    version: response.version,
    headers: response.headers,
    body,
  }
}
