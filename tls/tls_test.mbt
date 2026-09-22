///|
test "tls: defaults require peer identity and disable early data" {
  let options = @tls.TlsOptions::defaults()
  assert_eq(options.verify_peer, true)
  assert_eq(options.enable_early_data, false)
  assert_true(options.validate() is Err(MissingServerName))
  let with_name = { ..options, server_name: Some("example.test"), }
  assert_eq(with_name.validate(), Ok(()))
  let early = { ..with_name, enable_early_data: true, }
  assert_true(early.validate() is Err(EarlyDataRequiresReplayPolicy))
}
