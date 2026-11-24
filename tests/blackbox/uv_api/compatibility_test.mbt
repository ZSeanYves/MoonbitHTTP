///|
async test "the uv import preserves callback methods and error constructors" {
  let transport : @uv.CallbackTransport = @uv.CallbackTransport::new(
    fn(_, _, _) { 0 },
    fn(_, _, len) { len + 1 },
  )
  try transport.write(b"x") catch {
    TransportError(@uv.InvalidWriteCount(2, limit=1), ..) => ()
    err => raise err
  } noraise {
    _ => fail("expected a write count error")
  }
  transport.close()
  try transport.write(b"x") catch {
    TransportError(@uv.CallbackTransportClosed, ..) => ()
    err => raise err
  } noraise {
    _ => fail("expected the closed transport error")
  }
}
