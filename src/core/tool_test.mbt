///|
test "headers: has_token_ci tolerates semicolon params (1)" {
  let h : Map[String, String] = Map::new()
  h.set("Transfer-Encoding", "gzip,   chunked;foo=bar")
  assert_eq(has_token_ci(h, "transfer-encoding", "chunked"), true)
}

///|
test "headers: has_token_ci tolerates semicolon params (2)" {
  let h : Map[String, String] = Map::new()
  h.set("Transfer-Encoding", "gzip")
  assert_eq(has_token_ci(h, "transfer-encoding", "chunked"), false)
}

///|
test "headers: has_token_ci tolerates semicolon params (3)" {
  let h : Map[String, String] = Map::new()
  h.set("TRANSFER-ENCODING", "GZip ,   ChUnKeD ; q=1")
  assert_eq(has_token_ci(h, "transfer-encoding", "chunked"), true)
}

///|
test "headers: get_ci is case-insensitive" {
  let h = Map::new()
  h.set("CONTENT-Length", " 7 ")
  assert_eq(get_ci(h, "content-length").unwrap(), " 7 ")
}
