///|
test "server shutdown stays started after repeated requests" {
  let signal = @service.ServerShutdown::new()
  assert_false(signal.has_started())
  signal.begin()
  assert_true(signal.has_started())
  signal.begin()
  assert_true(signal.has_started())
}
