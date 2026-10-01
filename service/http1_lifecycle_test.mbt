///|
priv suberror Http1LifecycleFailure {
  Http1LifecycleFailure(String)
} derive(Debug)

///|
struct Http1LifecycleBody {
  failure : Error?
  cancelled : Array[Error]
}

///|
impl @body.Body for Http1LifecycleBody with fn next_frame(self) {
  match self.failure {
    Some(error) => raise error
    None => None
  }
}

///|
impl @body.Body for Http1LifecycleBody with fn size_hint(_self) {
  @body.SizeHint::unknown()
}

///|
impl @body.Body for Http1LifecycleBody with fn cancel(self, error) {
  self.cancelled.push(error)
}

///|
fn http1_lifecycle_error_label(error : Error) -> String {
  match error {
    Http1LifecycleFailure(message) => message
    @http1.Http1Error::InvalidStartLine(_) => "invalid head"
    @body.BodyError::Cancelled => "cancelled"
    _ => if @async.is_cancellation_error(error) { "cancelled" } else { "other" }
  }
}

///|
fn http1_lifecycle_response(
  body : Http1LifecycleBody,
  status? : Int = 200,
) -> @types.Response[Http1LifecycleBody] {
  { status, version: Http11, headers: @types.HeaderMap::new(), body, }
}

///|
enum Http1FailingHeaderWriter {
  Failing
}

///|
fn http1_failing_header_writer() -> Http1FailingHeaderWriter {
  Failing
}

///|
impl @aio.Writer for Http1FailingHeaderWriter with fn write_once(
  _self,
  _data,
  offset~,
  len~,
) {
  ignore(offset)
  ignore(len)
  raise Http1LifecycleFailure("header write")
}

///|
struct Http1BlockedHeaderWriter {
  started : @aqueue.Queue[Unit]
  gate : @aqueue.Queue[Unit]
}

///|
impl @aio.Writer for Http1BlockedHeaderWriter with fn write_once(
  self,
  _data,
  offset~,
  len~,
) {
  ignore(offset)
  self.started.put(())
  self.gate.get()
  len
}

///|
async test "service: HTTP/1 header write failure cancels response body once with its cause" {
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(b"GET / HTTP/1.1\r\nHost: example.test\r\n\r\n")
  })
  let cancelled : Array[Error] = []
  let closed : Array[String] = []
  let body : Http1LifecycleBody = { failure: None, cancelled, }
  let config = {
    ..@service.ServerConfig::defaults(),
    close_callback: Some(fn(error) {
      closed.push(error.map(http1_lifecycle_error_label).unwrap_or("ok"))
    }),
  }
  try
    @service.serve_http1_connection(
      reader,
      http1_failing_header_writer(),
      fn(_) { http1_lifecycle_response(body) },
      config~,
    )
  catch {
    Http1LifecycleFailure("header write") => ()
    error => fail("changed header failure: \{error}")
  } noraise {
    _ => fail("header write unexpectedly succeeded")
  }
  assert_eq(cancelled.map(http1_lifecycle_error_label), ["header write"])
  assert_eq(closed, ["header write"])
}

///|
async test "service: HTTP/1 invalid response head cancels its unpolled body" {
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(b"GET / HTTP/1.1\r\nHost: example.test\r\n\r\n")
  })
  let cancelled : Array[Error] = []
  let body : Http1LifecycleBody = { failure: None, cancelled, }
  let writer : CaptureWriter = { bytes: [], }
  try
    @service.serve_http1_connection(reader, writer, fn(_) {
      http1_lifecycle_response(body, status=99)
    })
  catch {
    @http1.Http1Error::InvalidStartLine(_) => ()
    error => fail("changed head validation failure: \{error}")
  } noraise {
    _ => fail("invalid response head was accepted")
  }
  assert_eq(writer.bytes.length(), 0)
  assert_eq(cancelled.map(http1_lifecycle_error_label), ["invalid head"])
}

///|
async test "service: HTTP/1 request body failure is cancelled once and preserves its cause" {
  let reader = @aio.MemoryReader(fn(_writer) { () })
  let writer : CaptureWriter = { bytes: [], }
  let client = @service.ClientConnection::new(reader, writer).unwrap()
  let cancelled : Array[Error] = []
  let body : Http1LifecycleBody = {
    failure: Some(Http1LifecycleFailure("request body")),
    cancelled,
  }
  try client.send(phase_timeout_request(body)) catch {
    Http1LifecycleFailure("request body") => ()
    error => fail("changed request body failure: \{error}")
  } noraise {
    _ => fail("request body unexpectedly succeeded")
  }
  assert_eq(cancelled.map(http1_lifecycle_error_label), ["request body"])
  assert_true(client.is_closed())
}

///|
async test "service: HTTP/1 error response failure cancels body and closes once" {
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(b"GET / HTTP/1.1\r\nHost: example.test\r\n\r\n")
  })
  let writer : CaptureWriter = { bytes: [], }
  let cancelled : Array[Error] = []
  let closed : Array[String] = []
  let body : Http1LifecycleBody = {
    failure: Some(Http1LifecycleFailure("fallback body")),
    cancelled,
  }
  let config = {
    ..@service.ServerConfig::defaults(),
    close_callback: Some(fn(error) {
      closed.push(error.map(http1_lifecycle_error_label).unwrap_or("ok"))
    }),
  }
  try
    @service.serve_http1_with_error_responder(
      reader,
      writer,
      fn(_) raise { raise Http1LifecycleFailure("handler") },
      fn(_) { http1_lifecycle_response(body, status=500) },
      config~,
    )
  catch {
    Http1LifecycleFailure("fallback body") => ()
    error => fail("changed fallback failure: \{error}")
  } noraise {
    _ => fail("error response body unexpectedly succeeded")
  }
  assert_eq(cancelled.map(http1_lifecycle_error_label), ["fallback body"])
  assert_eq(closed, ["fallback body"])
}

///|
async test "service: HTTP/1 successful error response retains original close cause" {
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(b"GET / HTTP/1.1\r\nHost: example.test\r\n\r\n")
  })
  let writer : CaptureWriter = { bytes: [], }
  let cancelled : Array[Error] = []
  let closed : Array[String] = []
  let body : Http1LifecycleBody = { failure: None, cancelled, }
  let config = {
    ..@service.ServerConfig::defaults(),
    close_callback: Some(fn(error) {
      closed.push(error.map(http1_lifecycle_error_label).unwrap_or("ok"))
    }),
  }
  @service.serve_http1_with_error_responder(
    reader,
    writer,
    fn(_) raise { raise Http1LifecycleFailure("handler") },
    fn(_) { http1_lifecycle_response(body, status=500) },
    config~,
  )
  assert_eq(cancelled.length(), 0)
  assert_eq(closed, ["handler"])
}

///|
async test "service: cancelling HTTP/1 error response closes once and cancels its body" {
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(b"GET / HTTP/1.1\r\nHost: example.test\r\n\r\n")
  })
  let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let writer : Http1BlockedHeaderWriter = {
    started,
    gate: Queue(kind=Unbounded),
  }
  let cancelled : Array[Error] = []
  let closed : Array[Bool] = []
  let body : Http1LifecycleBody = { failure: None, cancelled, }
  let config = {
    ..@service.ServerConfig::defaults(),
    write_timeout_ms: None,
    close_callback: Some(fn(error) { closed.push(error is Some(_)) }),
  }
  @async.with_timeout(1000, async fn() {
    @async.with_task_group(async fn(group) {
      let task = group.spawn(async fn() {
        @service.serve_http1_with_error_responder(
          reader,
          writer,
          fn(_) raise { raise Http1LifecycleFailure("handler") },
          fn(_) { http1_lifecycle_response(body, status=500) },
          config~,
        )
      })
      started.get()
      task.cancel()
      try task.wait() catch {
        error => assert_true(@async.is_cancellation_error(error))
      } noraise {
        _ => fail("cancelled error response completed normally")
      }
    })
  })
  assert_eq(cancelled.map(http1_lifecycle_error_label), ["cancelled"])
  assert_eq(closed, [true])
}
