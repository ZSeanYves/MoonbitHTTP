///|
async test "http-test: fault reader raises at configured boundary" {
  let reader = @test_support.FaultReader::new([b"a", b"b"], fail_after=Some(1))
  assert_eq(reader.read(), Some(b"a"))
  let raised = try {
    ignore(reader.read())
    false
  } catch {
    _ => true
  }
  assert_eq(raised, true)
}
