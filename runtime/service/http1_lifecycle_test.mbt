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
    _ => "other"
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
        @async.WaitedTaskAlreadyCancelled => ()
        _ => fail("cancelled error response changed its terminal state")
      } noraise {
        _ => fail("cancelled error response completed normally")
      }
    })
  })
  assert_eq(cancelled.map(http1_lifecycle_error_label), ["cancelled"])
  assert_eq(closed, [true])
}

///|
async test "HTTP/1 stops after a closing exchange and honors explicit HTTP/1.0 persistence" {
  for
    (first, response_closes, expected_calls, expected_connection) in [
      (
        b"GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n", false, 1,
        "close",
      ),
      (b"GET / HTTP/1.1\r\nHost: local\r\n\r\n", true, 1, "close"),
      (
        b"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", false, 2, "keep-alive",
      ),
      (
        b"GET / HTTP/1.0\r\nConnection: keep-alive, close\r\n\r\n", false, 1, "close",
      ),
    ] {
    let reader = @aio.MemoryReader(async fn(writer) {
      writer.write(
        first +
        b"GET /second HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n",
      )
    })
    defer reader.close()
    let writer : CaptureWriter = { bytes: [], }
    let mut calls = 0
    @service.serve_http1_connection(reader, writer, request => {
      calls += 1
      let headers = @types.HeaderMap::new()
      if response_closes {
        headers.append_string("connection", "close").unwrap()
      }
      {
        status: 200,
        version: request.version,
        headers,
        body: @body.FullBody::new(b"ok"),
      }
    })
    assert_eq(calls, expected_calls)
    let wire = @utf8.decode_lossy(Bytes::from_array(writer.bytes)).to_lower()
    assert_true(wire.contains("connection: " + expected_connection + "\r\n"))
  }
}

///|
async test "HTTP/1 selection preserves a coalesced body and the next request" {
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(b"POST /one HTTP/1.1\r\nHost: example.test\r\nContent-Len")
    peer.write(
      b"gth: 4\r\n\r\ndataGET /two HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n",
    )
  })
  defer reader.close()
  let writer : CaptureWriter = { bytes: [], }
  let seen : Array[(String, Bytes)] = []
  @service.serve_http1_or_h2c_connection(reader, writer, async fn(request) {
    let (data, _) = @body.collect(request.body)
    seen.push((request.uri.value, data))
    {
      status: 200,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: @body.FullBody::new(data),
    }
  })
  assert_eq(seen, [("/one", b"data"), ("/two", b"")])
}

///|
async test "HTTP/1 and h2c reject an unsupported expectation before dispatch" {
  for
    head in [
      b"HEAD / HTTP/1.1\r\nHost: example.test\r\nExpect: custom\r\n\r\n", b"POST / HTTP/1.1\r\nHost: example.test\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAQAAP__\r\nContent-Length: 8\r\nExpect: 100-continue, custom\r\n\r\n",
    ] {
    let reader = @aio.MemoryReader(async fn(peer) { peer.write(head) })
    defer reader.close()
    let writer : CaptureWriter = { bytes: [], }
    @service.serve_http1_or_h2c_connection(reader, writer, _ => {
      (
        fail("unsupported expectation reached the handler") :
        @types.Response[@body.EmptyBody])
    })
    let wire = Bytes::from_array(writer.bytes)
    assert_true(wire.has_prefix(b"HTTP/1.1 417 Expectation Failed\r\n"))
    assert_true(wire.find(b"connection: close\r\n") is Some(_))
  }
}

///|
async test "a successful CONNECT leaves the sequential HTTP/1 connection" {
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(b"HTTP/1.1 200 OK\r\n\r\ntunnel")
  })
  defer reader.close()
  let client = @service.ClientConnection::new(reader, CaptureWriter::{
    bytes: [],
  }).unwrap()
  let base = phase_timeout_request(@body.EmptyBody::new())
  let response = client.send({
    ..base,
    http_method: Connect,
    uri: @types.Uri::parse_request_target("example.test:443", Connect).unwrap(),
  })
  assert_eq(@body.collect(response.body).0, b"")
  assert_true(client.is_closed())
}
