///|
async test "SWR refreshes credential variants independently and releases work on scope exit" {
  let cache = @cache.HttpCache::new().unwrap()
  let requests = ["a", "b"].map(user => {
    let fields = @types.HeaderMap::new()
    fields.append_string("authorization", "Bearer " + user).unwrap()
    fields.append_string("cookie", "session=" + user).unwrap()
    pooled_request("http://origin.test/account", fields)
  })
  for index, request in requests {
    let headers = @types.HeaderMap::new()
    headers
    .append_string(
      "cache-control", "private, max-age=1, stale-while-revalidate=10",
    )
    .unwrap()
    headers.append_string("vary", "authorization, cookie").unwrap()
    headers
    .append_string("etag", if index == 0 { "\"first\"" } else { "\"second\"" })
    .unwrap()
    ignore(
      cache
      .store(
        request.map_body(_ => ()),
        { status: 200, version: Http11, headers, body: (), },
        if index == 0 {
          b"first"
        } else {
          b"second"
        },
        0L,
      )
      .unwrap(),
    )
  }
  let started : @aqueue.Queue[(String, String, String)] = Queue(kind=Unbounded)
  let block : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let mut ended = 0
  @async.with_timeout(3000, async fn() {
    @client.with_client(
      async fn(client) {
        for index, request in requests {
          assert_eq(
            send_bytes(client, request).body,
            if index == 0 {
              b"first"
            } else {
              b"second"
            },
          )
          let expected = if index == 0 {
            ("Bearer a", "session=a", "\"first\"")
          } else {
            ("Bearer b", "session=b", "\"second\"")
          }
          assert_eq(started.get(), expected)
        }
        assert_eq(send_bytes(client, requests[0]).body, b"first")
      },
      version=Http11,
      cache~,
      cache_enabled=true,
      now_millis=() => 0L,
      wall_clock_seconds=() => 2L,
      authorize_redirect=(_, _) => Ok(()),
      exchange=byte_peer(request => {
        defer {
          ended += 1
        }
        fn value(name : String) -> String {
          request.headers.get_string(name).unwrap().to_string_lossy()
        }
        started.put(
          (value("authorization"), value("cookie"), value("if-none-match")),
        )
        block.get()
        Err(ClientProtocol("unexpected refresh completion"))
      }),
    )
  })
  assert_eq(ended, 2)
  assert_eq(cache.len(), 2)
}
