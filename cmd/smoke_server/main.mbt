///|
async fn main {
  let server = @socket.TcpServer(
    @socket.Addr::parse("127.0.0.1:18080"),
    reuse_addr=true,
  )
  server.run_forever(async fn(connection, _address) {
    @service.serve_auto_connection(connection, connection, async fn(request) {
      @async.pause()
      let headers = @types.HeaderMap::new()
      ignore(headers.append_string("content-type", "text/plain"))
      let body = if request.http_method == Post {
        request.body
      } else {
        let stream = @body.BodyStream::new(capacity=2)
        stream.push(Data(b"MoonbitHTTP smoke\n"))
        stream.finish()
        stream
      }
      { status: 200, version: request.version, headers, body }
    }) catch {
      error => println("connection error: \{error}")
    }
  })
}
