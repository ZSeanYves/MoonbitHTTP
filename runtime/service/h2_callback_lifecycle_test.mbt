///|
async test "H2 client callback return cancels suspended upload and reader" {
  let writer = H2LifecycleWriter::new()
  defer writer.signal.close()
  let mut source_cancellations = 0
  let upload = @body.BodyStream::new(on_cancel=fn(_) {
    source_cancellations += 1
  }).unwrap()
  let reader = @aio.MemoryReader(async fn(peer) {
    ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 1))
    peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    peer.write(security_h2_response_head(204, None, true))
    @async.sleep(60_000)
  })
  defer reader.close()
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(reader, writer, async fn(client) {
      let response = client.send(
        security_request(Post).map_body(fn(_) { upload }),
      )
      assert_eq(response.status, 204)
    })
  })
  assert_eq(source_cancellations, 1)
}
