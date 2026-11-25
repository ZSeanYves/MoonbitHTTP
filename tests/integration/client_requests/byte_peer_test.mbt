///|
/// Adapt small byte fixtures at the test boundary. Policy always runs against the streaming API.
fn byte_peer(
  peer : async (@types.Request[Bytes]) -> Result[
    @types.Response[Bytes],
    @client.ClientError,
  ],
) -> async (@types.Request[@client.IncomingBody]) -> @types.Response[
  @client.IncomingBody,
] {
  async fn(request) {
    let (data, _) = @body.collect(request.body)
    let response = peer(request.map_body(_ => data)).unwrap_or_error()
    response.map_body(bytes => {
      @client.IncomingBody::wrap(@body.FullBody::new(bytes))
    })
  }
}

///|
async fn send_bytes(
  client : @client.Client,
  request : @types.Request[Bytes],
  once~ : Bool = false,
) -> @types.Response[Bytes] {
  let response = client.send(
    request.map_body(data => {
      if once {
        @client.Upload::once(@body.FullBody::new(data))
      } else {
        @client.Upload::bytes(data)
      }
    }),
  )
  let (data, _) = @body.collect(response.body)
  response.map_body(_ => data)
}
