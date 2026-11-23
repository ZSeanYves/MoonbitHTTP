///|
async fn run_peer_soak(
  address : String,
  authority : String,
  trust_file : String,
  seconds : Int32,
  workers : Int32,
) -> Unit {
  guard seconds >= 1 && seconds <= 3600 && workers >= 1 && workers <= 32 else {
    fail("expected 1–3600 seconds and 1–32 concurrent workers")
  }
  let udp = @types.Authority::parse_endpoint(address).unwrap_or_error()
  guard udp.port is Some(port) else { fail("UDP peer requires a port") }
  let ip = @types.IpAddress::parse(udp.host).unwrap_or_error()
  let endpoint = @types.Endpoint::new("udp", ip.value(), port).unwrap_or_error()
  let origin = @types.Authority::parse_endpoint(authority).unwrap_or_error()
  let tls = {
    ..@transport.TlsOptions::for_quic(origin.host),
    trust_anchors: Some(@fs.read_binary(trust_file)),
  }
  let base = "https://" + authority
  let download = Bytes::make(4096, b'Z')
  // One authenticated scope owns the connection for the whole measurement.
  // Each worker keeps one request in flight and checks complete response bytes.
  @native_client.with_http3_client(
    endpoint,
    @transport.AllowAllPolicy::new(),
    tls,
    origin_port=Some(origin.port.unwrap_or(443)),
    async fn(client) {
      let clock = @transport_native.NativeClock::new()
      let start = @transport.Clock::monotonic_millis(clock)
      let deadline = start + seconds.to_int64() * 1000L
      let mut pairs = 0L
      defer {
        let elapsed = @transport.Clock::monotonic_millis(clock) - start
        let snapshot : Json = {
          "workers": workers,
          "elapsed_ms": elapsed.to_int(),
          "completed_pairs": pairs.to_double(),
          "verified_response_bytes": (pairs * 8192L).to_double(),
        }
        println(snapshot.stringify())
      }
      @async.with_task_group(fn(group) {
        for worker in 0..<workers {
          group.spawn_bg(async fn() {
            let payload = echo_payload(worker)
            while true {
              @async.with_timeout(30000, async fn() {
                check_body(
                  client.send(request(base + "/echo", Post, payload)),
                  payload,
                )
                check_body(
                  client.send(request(base + "/4096", Get, b"")),
                  download,
                )
              })
              pairs += 1L
              if @transport.Clock::monotonic_millis(clock) >= deadline {
                break
              }
            }
          })
        }
      })
    },
  )
}
