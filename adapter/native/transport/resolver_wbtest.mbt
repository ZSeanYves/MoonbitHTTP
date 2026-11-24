///|
test "native resolver preserves system order and bounds unique same-family results" {
  let candidates = [b"127.0.0.2", b"127.0.0.2", b"127.0.0.1", b"::1"]
  let mut index = 0
  let addresses = collect_addresses(2, fn() {
    let bytes = candidates[index]
    index += 1
    bytes
  }).unwrap()
  assert_eq(addresses.map(address => address.value()), [
    "127.0.0.2", "127.0.0.1",
  ])
  assert_eq(index, 3)
}
