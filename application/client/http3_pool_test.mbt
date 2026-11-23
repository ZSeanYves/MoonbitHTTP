///|
async test "HTTP/3 pool validates before waiting and cancels a shared opener only after the last caller leaves" {
  @async.with_timeout(3000, async fn() {
    let entered : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let exited : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let release : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let cancelled : @aqueue.Queue[String] = Queue(kind=Unbounded)
    let mut opens = 0
    fn request(
      uri : String,
      label : String,
    ) -> @types.Request[@body.BodyStream] {
      {
        http_method: Post,
        uri: @types.Uri::parse(uri).unwrap(),
        version: Http3,
        headers: @types.HeaderMap::new(),
        body: @body.BodyStream::from_pull(() => fail("unsent body was read"), on_cancel=_ => {
          ignore(cancelled.try_put(label) catch { _ => false })
        }),
      }
    }
    @client.with_http3_pool(
      async fn(_, _, _) {
        opens += 1
        entered.put(())
        defer ignore(exited.try_put(()) catch { _ => false })
        release.get()
        raise @transport.TransportError::Failed(Resolve, "resolver stopped")
      },
      async fn(pool) {
        let origin = "https://api.test/upload"
        @async.with_task_group(async fn(group) {
          let first = group.spawn(async fn() {
            ignore(pool.send(request(origin, "first")))
          })
          entered.get()
          let second = group.spawn(async fn() {
            ignore(pool.send(request(origin, "second")))
          })
          @async.pause()
          first.cancel()
          assert_eq(cancelled.get(), "first")
          assert_true(exited.try_get() is None)
          for bad in ["https://other.test/", "http://api.test/"] {
            try ignore(pool.send(request(bad, bad))) catch {
              @service.H3ClientError::InvalidOrigin => ()
              error => raise error
            } noraise {
              _ => fail("invalid origin accepted")
            }
            assert_eq(cancelled.get(), bad)
          }
          assert_eq(opens, 1)
          second.cancel()
          exited.get()
          assert_eq(cancelled.get(), "second")
          let fresh = group.spawn(async fn() {
            try ignore(pool.send(request(origin, "fresh"))) catch {
              @transport.TransportError::Failed(Resolve, "resolver stopped") =>
                ()
              error => raise error
            } noraise {
              _ => fail("opener failure was lost")
            }
          })
          entered.get()
          release.put(())
          fresh.wait()
          assert_eq(cancelled.get(), "fresh")
          assert_eq(opens, 2)
          assert_eq(pool.connection_count(), 0)
        })
      },
      max_connections=1,
      server_name=Some("API.TEST"),
    )
  })
}
