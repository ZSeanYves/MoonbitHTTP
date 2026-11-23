///|
struct H2PoolPeer {
  replies : @aqueue.Queue[Bytes]
  ack : @aqueue.Queue[Unit]
  mut closed : Bool
  authorities : Array[Bytes]
}

///|
struct H2PoolConnector {
  peers : Array[H2PoolPeer]
  mut fail_initial_read : Bool
  opened : @aqueue.Queue[H2PoolPeer]
  mut hold_settings : Bool
}

///|
fn H2PoolConnector::new() -> H2PoolConnector {
  {
    peers: [],
    fail_initial_read: false,
    opened: Queue(kind=Unbounded),
    hold_settings: false,
  }
}

///|
impl @transport.StreamConnector for H2PoolConnector with fn connect(
  self,
  endpoint,
  _options,
) {
  let peer : H2PoolPeer = {
    replies: Queue(kind=Unbounded),
    ack: Queue(kind=Unbounded),
    closed: false,
    authorities: [],
  }
  self.peers.push(peer)
  let decoder = @http2.FrameDecoder::new()
  let headers = @http2.HpackContext::new()
  let encoder = @http2.HpackContext::new()
  self.opened.put(peer)
  if !self.hold_settings {
    peer.replies.put(
      Bytes::from_array(
        @http2.encode_settings_frame([{ id: 3, value: 1, }], false),
      ),
    )
  }
  Ok(
    @transport.StreamConnection::new(
      endpoint,
      async fn(_) {
        if self.fail_initial_read {
          self.fail_initial_read = false
          return Err(Failed(Receive, "initial read failed"))
        }
        Ok(Some(peer.replies.get()))
      },
      async fn(bytes) {
        if bytes == b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
          return Ok(())
        }
        decoder.feed(bytes).unwrap()
        while decoder.next().unwrap() is Some(frame) {
          if frame.header.typ == @http2.H2_FRAME_PING {
            peer.ack.put(())
          }
          if frame.header.typ != @http2.H2_FRAME_HEADERS {
            continue
          }
          let fields = headers
            .decode(@http2.header_fragment(frame).unwrap())
            .unwrap()
          let mut hold = false
          for field in fields {
            match field.name {
              ":authority" => peer.authorities.push(field.value)
              ":path" => hold = field.value == b"/hold"
              "proxy-authorization" | "host" => fail("unexpected origin header")
              _ => ()
            }
          }
          let head : @types.Response[Unit] = {
            status: 200,
            version: Http2,
            headers: @types.HeaderMap::new(),
            body: (),
          }
          peer.replies.put(
            @http2.encode_response_headers(
              encoder,
              frame.header.stream_id,
              head,
              !hold,
            ).unwrap(),
          )
        }
        Ok(())
      },
      fn() {
        peer.closed = true
        peer.replies.close()
      },
    ),
  )
}

///|
async fn[X] with_pool_peer(
  connector : H2PoolConnector,
  run : async (@client.Http2Client) -> X,
  max_connections? : Int = 2,
) -> X {
  let ip = @types.IpAddress::parse("127.0.0.1").unwrap()
  @client.with_http2_client(
    connector,
    @transport.StaticResolver::new([("first.test", [ip]), ("second.test", [ip])]),
    @transport.UnsupportedProvider::new(),
    @transport.AllowAllPolicy::new(),
    @test_support.FixedClock::new(0L, 0L),
    run,
    options={ ..@client.Http2PoolOptions::defaults(), max_connections, },
  )
}

///|
async test "managed h2 shares cold dials, isolates origins and releases broken openings" {
  let connector = H2PoolConnector::new()
  connector.fail_initial_read = true
  with_pool_peer(
    connector,
    async fn(client) {
      let headers = @types.HeaderMap::new()
      headers.append_string("host", "original.test").unwrap()
      headers.append_string("proxy-authorization", "proxy-only").unwrap()
      let request = pooled_request("http://first.test/", headers)
      assert_true(
        client.execute(request) is Err(ClientTransport(Failed(Receive, _))),
      )
      assert_true(connector.peers[0].closed)
      @async.with_task_group(fn(group) {
        for _ in 0..<8 {
          group.spawn_bg(async fn() {
            assert_eq(client.execute(request).unwrap().status, 200)
          })
        }
      })
      assert_eq(connector.peers.length(), 2)
      assert_eq(connector.peers[1].authorities, Array::make(8, b"first.test"))
      let explicit = pooled_request("http://FIRST.test:80/", headers)
      assert_eq(client.execute(explicit).unwrap().status, 200)
      assert_eq(connector.peers.length(), 2)
      assert_eq(
        client.execute(pooled_request("http://second.test/", headers)).unwrap().status,
        200,
      )
      assert_eq(connector.peers.length(), 3)
      assert_true(connector.peers[1].closed)
      assert_eq(connector.peers[2].authorities, [b"second.test"])
      assert_eq(headers.fields().length(), 2)
    },
    max_connections=1,
  )
  assert_true(connector.peers[2].closed)
}

///|
async test "managed h2 drains an accepted response across GOAWAY and replaces the session" {
  let connector = H2PoolConnector::new()
  with_pool_peer(connector, async fn(client) {
    let headers = @types.HeaderMap::new()
    let first = client
      .execute_stream(pooled_request("http://first.test/hold", headers))
      .unwrap()
    let old = connector.peers[0]
    // GOAWAY(last_stream_id=1, NO_ERROR), then a PING as a processing barrier.
    old.replies.put(
      b"\x00\x00\x08\x07\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00",
    )
    old.replies.put(b"\x00\x00\x08\x06\x00\x00\x00\x00\x00abcdefgh")
    old.ack.get()
    let next = client
      .execute(pooled_request("http://first.test/", headers))
      .unwrap()
    assert_eq(next.status, 200)
    assert_eq(connector.peers.length(), 2)
    assert_false(old.closed)
    old.replies.put(@http2.encode_data_frames(1, b"complete", true).unwrap())
    let (bytes, _) = @body.collect(first.body)
    assert_eq(bytes, b"complete")
  })
  assert_true(connector.peers[0].closed && connector.peers[1].closed)
}

///|
async test "cancelling the last HTTP/2 opener releases a socket waiting for SETTINGS" {
  let connector = H2PoolConnector::new()
  connector.hold_settings = true
  with_pool_peer(
    connector,
    async fn(client) {
      let headers = @types.HeaderMap::new()
      @async.with_task_group(async fn(group) {
        let waiting = group.spawn(async fn() {
          ignore(client.execute(pooled_request("http://first.test/", headers)))
        })
        let first = connector.opened.get()
        waiting.cancel()
        connector.hold_settings = false
        assert_eq(
          client
          .execute(pooled_request("http://second.test/", headers))
          .unwrap().status,
          200,
        )
        assert_true(first.closed)
      })
    },
    max_connections=1,
  )
}

///|
struct H2PoolTls {
  mut alpn : String?
  mut authenticated : Bool
}

///|
impl @transport.TlsProvider for H2PoolTls with fn client_handshake(
  self,
  stream,
  options,
) {
  assert_eq(options.alpn, ["h2"])
  assert_eq(options.server_name, Some("first.test"))
  Ok(
    @transport.SecureConnection::new(
      stream,
      Tls13,
      "test",
      self.alpn,
      Some("first.test"),
      self.authenticated,
    ),
  )
}

///|
impl @transport.TlsProvider for H2PoolTls with fn server_handshake(_, _, _) {
  Err(Unsupported)
}

///|
async test "managed HTTPS checks negotiated h2 and authentication before sending a request" {
  let connector = H2PoolConnector::new()
  let tls : H2PoolTls = { alpn: None, authenticated: true, }
  let resolver = @transport.StaticResolver::new([
    ("first.test", [@types.IpAddress::parse("127.0.0.1").unwrap()]),
  ])
  @client.with_http2_client(
    connector,
    resolver,
    tls,
    @transport.AllowAllPolicy::new(),
    @test_support.FixedClock::new(0L, 0L),
    async fn(client) {
      let request = pooled_request(
        "https://first.test/",
        @types.HeaderMap::new(),
      )
      assert_true(client.execute(request) is Err(ClientProtocol(_)))
      tls.alpn = Some("http/1.1")
      assert_true(client.execute(request) is Err(ClientProtocol(_)))
      tls.alpn = Some("h2")
      tls.authenticated = false
      assert_true(
        client.execute(request) is Err(ClientTls(VerificationFailed(_))),
      )
      for peer in connector.peers {
        assert_true(peer.closed && peer.authorities.is_empty())
      }
      tls.authenticated = true
      assert_eq(client.execute(request).unwrap().status, 200)
    },
  )
}

///|
async test "managed h2 rejects a peer that acknowledges settings before sending its own" {
  let connector = H2PoolConnector::new()
  connector.hold_settings = true
  with_pool_peer(connector, async fn(client) {
    @async.with_task_group(async fn(group) {
      let request = pooled_request(
        "http://first.test/",
        @types.HeaderMap::new(),
      )
      let exchange = group.spawn(async fn() { client.execute(request) })
      let peer = connector.opened.get()
      peer.replies.put(
        Bytes::from_array(@http2.encode_settings_frame([], true)),
      )
      assert_true(
        exchange.wait() is Err(ClientHttp2(ConnectionError(ProtocolError, _))),
      )
      assert_true(peer.closed && peer.authorities.is_empty())
    })
  })
}
