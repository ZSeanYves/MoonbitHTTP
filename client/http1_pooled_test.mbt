///|
fn pooled_request(
  uri : String,
  headers : @types.HeaderMap,
) -> @types.Request[Bytes] {
  {
    http_method: Get,
    uri: @types.Uri::parse(uri).unwrap(),
    version: Http11,
    headers,
    body: b"",
  }
}

///|
fn pooled_client_error_message(error : @client.ClientError) -> String {
  match error {
    ClientInvalidUri(_) => "invalid URI"
    ClientInvalidEndpoint(_) => "invalid endpoint"
    ClientInvalidOptions(message) => "invalid options: " + message
    ClientRedirect(_) => "redirect"
    ClientRetry(_) => "retry"
    ClientPolicy(_) => "policy"
    ClientTransport(_) => "transport"
    ClientTls(_) => "TLS"
    ClientAuth(_) => "auth"
    ClientContentCoding(_) => "content coding"
    ClientBodyLimit(_) => "body limit"
    ClientBody(_) => "body"
    ClientTimeout(_, _, _) => "timeout"
    ClientCancelled(message) => "cancelled: " + message
    ClientProtocol(message) => "protocol: " + message
  }
}

///|
struct FacadeTestConnector {
  responses : Array[Bytes]
  mut response_index : Int
  connect_hosts : Array[String]
  writes : Array[Bytes]
  mut closes : Int
}

///|
impl @transport.StreamConnector for FacadeTestConnector with fn connect(
  self,
  endpoint,
  _options,
) {
  self.connect_hosts.push(endpoint.host())
  Ok(
    @transport.StreamConnection::new(
      endpoint,
      fn(_) {
        if self.response_index >= self.responses.length() {
          Ok(None)
        } else {
          let response = self.responses[self.response_index]
          self.response_index += 1
          Ok(Some(response))
        }
      },
      fn(bytes) {
        self.writes.push(bytes)
        Ok(())
      },
      fn() { self.closes += 1 },
    ),
  )
}

///|
async test "pooled HTTP/1: sequential requests reuse one physical connection" {
  let endpoint = @transport.Endpoint::new("http", "origin.test", 80).unwrap()
  let responses = [
    b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none", b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo",
  ]
  let mut response_index = 0
  let mut connects = 0
  let mut closes = 0
  let writes : Array[Bytes] = []
  let executor = @client.Http1PooledRoundTripper::new(
    (actual, _) => {
      assert_eq(actual, endpoint)
      connects += 1
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) {
            if response_index >= responses.length() {
              Ok(None)
            } else {
              let response = responses[response_index]
              response_index += 1
              Ok(Some(response))
            }
          },
          fn(bytes) {
            writes.push(bytes)
            Ok(())
          },
          fn() { closes += 1 },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
  ).unwrap()
  let headers = @types.HeaderMap::new()
  headers.append_string("host", "attacker.test").unwrap()
  headers.append_string("proxy-authorization", "Basic secret").unwrap()
  let request = pooled_request("http://origin.test/resource", headers)
  assert_eq(executor.execute(request).unwrap().body, b"one")
  assert_eq(executor.execute(request).unwrap().body, b"two")
  assert_eq(connects, 1)
  assert_eq(executor.connection_count(), 1)
  assert_eq(executor.idle_connection_count(), 1)
  assert_eq(writes.length(), 2)
  let first = @utf8.decode_lossy(writes[0])
  assert_true(first.has_prefix("GET /resource HTTP/1.1\r\n"))
  assert_true(first.contains("host: origin.test:80\r\n"))
  assert_true(!first.contains("attacker.test"))
  assert_true(!first.to_lower().contains("proxy-authorization"))
  executor.close()
  assert_eq(closes, 1)
}

///|
async test "pooled HTTP/1: cancelling a response destroys the lease" {
  let endpoint = @transport.Endpoint::new("http", "origin.test", 80).unwrap()
  let mut connects = 0
  let mut closes = 0
  let executor = @client.Http1PooledRoundTripper::new(
    (actual, _) => {
      assert_eq(actual, endpoint)
      connects += 1
      let mut sent = false
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) {
            if sent {
              Ok(None)
            } else {
              sent = true
              Ok(Some(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"))
            }
          },
          fn(_) { Ok(()) },
          fn() { closes += 1 },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
  ).unwrap()
  let request = pooled_request("http://origin.test/", @types.HeaderMap::new())
  let first = executor.execute_stream(request).unwrap()
  assert_eq(executor.idle_connection_count(), 0)
  first.body.cancel(@body.BodyError::Cancelled)
  assert_eq(closes, 1)
  assert_eq(executor.connection_count(), 0)
  let second = executor.execute(request).unwrap()
  assert_eq(second.body, b"data")
  assert_eq(connects, 2)
  assert_eq(executor.idle_connection_count(), 1)
  executor.close()
  assert_eq(closes, 2)
}

///|
async test "pooled HTTP/1: forward proxy uses absolute form and isolated credentials" {
  let proxy_endpoint = match
    @transport.Endpoint::new("http", "proxy.test", 8080) {
    Ok(value) => value
    Err(_) => fail("valid forward proxy endpoint was rejected")
  }
  let mut connects = 0
  let writes : Array[Bytes] = []
  let proxy = @client.ProxyConfig::http_forward(
    proxy_endpoint,
    identity_key=Some("account-a"),
  )
  let executor = @client.Http1PooledRoundTripper::new(
    (actual, _) => {
      assert_eq(actual, proxy_endpoint)
      connects += 1
      let mut sent = false
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) {
            if sent {
              Ok(None)
            } else {
              sent = true
              Ok(Some(b"HTTP/1.1 204 No Content\r\n\r\n"))
            }
          },
          fn(bytes) {
            writes.push(bytes)
            Ok(())
          },
          fn() { () },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
    proxy~,
  ).unwrap()
  let headers = @types.HeaderMap::new()
  headers.append_string("proxy-authorization", "Basic secret").unwrap()
  let response = executor
    .execute(pooled_request("http://origin.test/path?q=1", headers))
    .unwrap()
  assert_eq(response.status, 204)
  assert_eq(connects, 1)
  let wire = @utf8.decode_lossy(writes[0])
  assert_true(wire.has_prefix("GET http://origin.test/path?q=1 HTTP/1.1\r\n"))
  assert_true(wire.contains("proxy-authorization: Basic secret\r\n"))
  executor.close()
}

///|
async test "pooled HTTP/1: proxy credentials require an explicit pool identity" {
  let proxy_endpoint = @transport.Endpoint::new("http", "proxy.test", 8080).unwrap()
  let mut connects = 0
  let executor = @client.Http1PooledRoundTripper::new(
    (actual, _) => {
      connects += 1
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) { Ok(None) },
          fn(_) { Ok(()) },
          fn() { () },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
    proxy=@client.ProxyConfig::http_forward(proxy_endpoint),
  ).unwrap()
  let headers = @types.HeaderMap::new()
  headers.append_string("proxy-authorization", "Basic secret").unwrap()
  assert_true(
    executor.execute(pooled_request("http://origin.test/", headers))
    is Err(ClientInvalidOptions(_)),
  )
  assert_eq(connects, 0)
}

///|
async test "pooled HTTP/1: CONNECT isolates proxy auth and applies origin TLS" {
  let proxy_endpoint = match
    @transport.Endpoint::new("http", "proxy.test", 8080) {
    Ok(value) => value
    Err(_) => fail("valid CONNECT proxy endpoint was rejected")
  }
  let reads = [
    b"HTTP/1.1 200 Connection Established\r\n\r\n", b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
  ]
  let mut read_index = 0
  let writes : Array[Bytes] = []
  let tls_hosts : Array[String] = []
  let executor = @client.Http1PooledRoundTripper::new(
    (actual, _) => {
      assert_eq(actual, proxy_endpoint)
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) {
            if read_index >= reads.length() {
              Ok(None)
            } else {
              let value = reads[read_index]
              read_index += 1
              Ok(Some(value))
            }
          },
          fn(bytes) {
            writes.push(bytes)
            Ok(())
          },
          fn() { () },
        ),
      )
    },
    fn(connection, options) {
      tls_hosts.push(options.server_name.unwrap_or(""))
      Ok(
        @tls.SecureConnection::new(
          connection,
          Tls13,
          "TLS_AES_128_GCM_SHA256",
          Some("http/1.1"),
          options.server_name,
          true,
        ),
      )
    },
    proxy=@client.ProxyConfig::https_connect(
      proxy_endpoint,
      identity_key=Some("account-a"),
    ),
  ).unwrap()
  let headers = @types.HeaderMap::new()
  headers.append_string("proxy-authorization", "Basic secret").unwrap()
  let response = match
    executor.execute(pooled_request("https://origin.test/private", headers)) {
    Ok(value) => value
    Err(error) =>
      fail("CONNECT execution failed: " + pooled_client_error_message(error))
  }
  assert_eq(response.body, b"ok")
  assert_eq(tls_hosts, ["origin.test"])
  assert_eq(writes.length(), 2)
  let tunnel = @utf8.decode_lossy(writes[0])
  let origin = @utf8.decode_lossy(writes[1])
  assert_true(tunnel.has_prefix("CONNECT origin.test:443 HTTP/1.1\r\n"))
  assert_true(tunnel.contains("proxy-authorization: Basic secret\r\n"))
  assert_true(origin.has_prefix("GET /private HTTP/1.1\r\n"))
  assert_true(!origin.to_lower().contains("proxy-authorization"))
  executor.close()
}

///|
async test "pooled HTTP/1: policy denial happens before socket creation" {
  let mut connects = 0
  let executor = @client.Http1PooledRoundTripper::new(
    (actual, _) => {
      connects += 1
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) { Ok(None) },
          fn(_) { Ok(()) },
          fn() { () },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
    authorize=fn(_, operation) {
      Err(Denied(operation, "blocked by test policy"))
    },
  ).unwrap()
  assert_true(
    executor.execute(
      pooled_request("http://origin.test/", @types.HeaderMap::new()),
    )
    is Err(ClientPolicy(_)),
  )
  assert_eq(connects, 0)
}

///|
async test "pooled HTTP/1: resolved IPs are authorized and connection fallback is bounded" {
  let policy_resolve_hosts : Array[String] = []
  let policy_connect_hosts : Array[String] = []
  let connect_hosts : Array[String] = []
  let mut response_sent = false
  let executor = @client.Http1PooledRoundTripper::new(
    (actual, _) => {
      connect_hosts.push(actual.host())
      if actual.host() == "192.0.2.1" {
        Err(Failed(Connect, "first address unavailable"))
      } else {
        Ok(
          @transport.StreamConnection::new(
            actual,
            fn(_) {
              if response_sent {
                Ok(None)
              } else {
                response_sent = true
                Ok(Some(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
              }
            },
            fn(_) { Ok(()) },
            fn() { () },
          ),
        )
      }
    },
    fn(_, _) { Err(Unsupported) },
    resolve=Some((host, options) => {
      assert_eq(host, "origin.test")
      assert_eq(options.max_results, 16)
      Ok([
        @transport.IpAddress::parse("192.0.2.1").unwrap(),
        @transport.IpAddress::parse("198.51.100.2").unwrap(),
      ])
    }),
    authorize=fn(endpoint, operation) {
      match operation {
        Resolve => policy_resolve_hosts.push(endpoint.host())
        Connect => policy_connect_hosts.push(endpoint.host())
        _ => ()
      }
      Ok(())
    },
  ).unwrap()
  let response = executor
    .execute(pooled_request("http://origin.test/", @types.HeaderMap::new()))
    .unwrap()
  assert_eq(response.body, b"ok")
  assert_eq(policy_resolve_hosts, ["origin.test"])
  assert_eq(policy_connect_hosts, ["192.0.2.1", "198.51.100.2"])
  assert_eq(connect_hosts, ["192.0.2.1", "198.51.100.2"])
  executor.close()
}

///|
async test "pooled HTTP/1: resolved IP policy denial precedes socket creation" {
  let mut connects = 0
  let executor = @client.Http1PooledRoundTripper::new(
    fn(actual, _) {
      connects += 1
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) { Ok(None) },
          fn(_) { Ok(()) },
          fn() { () },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
    resolve=Some(fn(_, _) {
      Ok([@transport.IpAddress::parse("127.0.0.1").unwrap()])
    }),
    authorize=fn(endpoint, operation) {
      if operation == Connect && endpoint.host() == "127.0.0.1" {
        Err(Denied(Connect, "loopback is forbidden"))
      } else {
        Ok(())
      }
    },
  ).unwrap()
  assert_true(
    executor.execute(
      pooled_request("http://origin.test/", @types.HeaderMap::new()),
    )
    is Err(ClientPolicy(Denied(Connect, _))),
  )
  assert_eq(connects, 0)
}

///|
async test "pooled HTTP/1: proxy preflights every resolved origin address" {
  let proxy_endpoint = @transport.Endpoint::new("http", "proxy.test", 8080).unwrap()
  let mut connects = 0
  let policy_operations : Array[@transport.PolicyOperation] = []
  let executor = @client.Http1PooledRoundTripper::new(
    fn(actual, _) {
      connects += 1
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) { Ok(None) },
          fn(_) { Ok(()) },
          fn() { () },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
    resolve=Some((host, _) => {
      assert_eq(host, "origin.test")
      Ok([@transport.IpAddress::parse("127.0.0.1").unwrap()])
    }),
    authorize=fn(endpoint, operation) {
      policy_operations.push(operation)
      if operation == Connect && endpoint.host() == "127.0.0.1" {
        Err(Denied(Connect, "loopback is forbidden"))
      } else {
        Ok(())
      }
    },
    proxy=@client.ProxyConfig::http_forward(proxy_endpoint),
  ).unwrap()
  assert_true(
    executor.execute(
      pooled_request("http://origin.test/", @types.HeaderMap::new()),
    )
    is Err(ClientPolicy(Denied(Connect, _))),
  )
  assert_eq(connects, 0)
  assert_eq(policy_operations, [Resolve, ProxyConnect, Resolve, Connect])
  executor.close()
}

///|
async test "pooled HTTP/1: CONNECT preflights resolved origin addresses" {
  let proxy_endpoint = @transport.Endpoint::new("http", "proxy.test", 8080).unwrap()
  let mut connects = 0
  let executor = @client.Http1PooledRoundTripper::new(
    fn(actual, _) {
      connects += 1
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) { Ok(None) },
          fn(_) { Ok(()) },
          fn() { () },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
    resolve=Some((_, _) => {
      Ok([@transport.IpAddress::parse("10.0.0.1").unwrap()])
    }),
    authorize=fn(endpoint, operation) {
      if operation == Connect && endpoint.host() == "10.0.0.1" {
        Err(Denied(Connect, "private address is forbidden"))
      } else {
        Ok(())
      }
    },
    proxy=@client.ProxyConfig::https_connect(proxy_endpoint),
  ).unwrap()
  assert_true(
    executor.execute(
      pooled_request("https://origin.test/", @types.HeaderMap::new()),
    )
    is Err(ClientPolicy(Denied(Connect, _))),
  )
  assert_eq(connects, 0)
  executor.close()
}

///|
async test "pooled HTTP/1: resolver timeout preserves the resolve phase" {
  let mut connects = 0
  let executor = @client.Http1PooledRoundTripper::new(
    fn(actual, _) {
      connects += 1
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) { Ok(None) },
          fn(_) { Ok(()) },
          fn() { () },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
    resolve=Some(fn(_, _) { Err(Timeout(Resolve)) }),
  ).unwrap()
  assert_true(
    executor.execute(
      pooled_request("http://origin.test/", @types.HeaderMap::new()),
    )
    is Err(ClientTimeout(ClientResolve, 10000L, 10000L)),
  )
  assert_eq(connects, 0)
}

///|
async test "HTTP/1 client facade owns policy, DNS, pool, clock, and shutdown" {
  let connector : FacadeTestConnector = {
    responses: [
      b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none", b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo",
    ],
    response_index: 0,
    connect_hosts: [],
    writes: [],
    closes: 0,
  }
  let resolver = @transport.StaticResolver::new([
    ("origin.test", [@transport.IpAddress::parse("192.0.2.10").unwrap()]),
  ])
  let client = @client.Http1Client::from_capabilities(
    connector,
    resolver,
    @tls.UnsupportedProvider::new(),
    @transport.AllowAllPolicy::new(),
    @transport.FixedClock::new(100L, 1700000000L),
  ).unwrap()
  let request = pooled_request(
    "http://origin.test/resource",
    @types.HeaderMap::new(),
  )
  assert_eq(client.send(request).unwrap().body, b"one")
  assert_eq(client.send(request).unwrap().body, b"two")
  assert_eq(connector.connect_hosts, ["192.0.2.10"])
  assert_eq(client.connection_count(), 1)
  assert_eq(client.idle_connection_count(), 1)
  assert_eq(connector.writes.length(), 2)
  client.close()
  assert_eq(connector.closes, 1)
}

///|
async test "pooled HTTP/1: capacity wait is released by body cancellation" {
  let mut connects = 0
  let mut closes = 0
  let executor = @client.Http1PooledRoundTripper::new(
    (actual, _) => {
      connects += 1
      let mut sent = false
      Ok(
        @transport.StreamConnection::new(
          actual,
          fn(_) {
            if sent {
              Ok(None)
            } else {
              sent = true
              Ok(Some(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"))
            }
          },
          fn(_) { Ok(()) },
          fn() { closes += 1 },
        ),
      )
    },
    fn(_, _) { Err(Unsupported) },
    pool_limits={ max_total: 1, max_idle: 1, },
  ).unwrap()
  let request = pooled_request("http://origin.test/", @types.HeaderMap::new())
  let first = executor.execute_stream(request).unwrap()
  let mut completed = false
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      let result = executor.execute(request)
      completed = result is Ok(_)
    })
    @async.pause()
    assert_false(completed)
    assert_eq(connects, 1)
    first.body.cancel(@body.BodyError::Cancelled)
    task.wait()
  })
  assert_true(completed)
  assert_eq(connects, 2)
  assert_eq(closes, 1)
  executor.close()
  assert_eq(closes, 2)
}
