///|
fn auth_test_header(value : String) -> @types.HeaderValue {
  @types.HeaderValue::from_string(value).unwrap()
}

///|
fn auth_test_challenge(value : String) -> @auth.DigestChallenge {
  @auth.DigestChallenge::parse_string(value).unwrap()
}

///|
fn auth_test_quoted_parameter(header : String, name : String) -> String? {
  let marker = name + "=\""
  let start = match header.find(marker) {
    Some(value) => value + marker.length()
    None => return None
  }
  let tail = header[start:]
  match tail.find("\"") {
    Some(value) => Some(tail[:value].to_owned())
    None => None
  }
}

///|
let rfc7616_nonce = "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v"

///|
let rfc7616_opaque = "FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"

///|
let rfc7616_cnonce = "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ"

///|
fn rfc7616_challenge(algorithm : String) -> @auth.DigestChallenge {
  auth_test_challenge(
    "Digest realm=\"http-auth@example.org\", qop=\"auth, auth-int\", " +
    "algorithm=" +
    algorithm +
    ", nonce=\"" +
    rfc7616_nonce +
    "\", opaque=\"" +
    rfc7616_opaque +
    "\"",
  )
}

///|
test "digest auth: RFC 7616 SHA-256 response vector" {
  let session = @auth.DigestSession::new(
    rfc7616_challenge("SHA-256"),
    @auth.DigestCredentials::new("Mufasa", "Circle of Life").unwrap(),
    "http://www.example.org:80",
  ).unwrap()
  let header = session
    .authorization(
      "http://www.example.org:80",
      Get,
      "/dir/index.html",
      rfc7616_cnonce,
    )
    .unwrap()
    .to_string_lossy()
  assert_eq(
    auth_test_quoted_parameter(header, "response"),
    Some("753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1"),
  )
  assert_true(header.contains("algorithm=SHA-256"))
  assert_true(header.contains("nc=00000001"))
  assert_true(header.contains("qop=auth"))
}

///|
test "digest auth: RFC 7616 MD5 vector requires an explicit weak-algorithm opt-in" {
  let challenge = rfc7616_challenge("MD5")
  let credentials = @auth.DigestCredentials::new("Mufasa", "Circle of Life").unwrap()
  assert_true(
    @auth.DigestSession::new(
      challenge, credentials, "http://www.example.org:80",
    )
    is Err(WeakDigestAlgorithmDenied),
  )
  let policy = { ..@auth.DigestPolicy::defaults(), allow_md5: true, }
  let session = @auth.DigestSession::new(
    challenge,
    credentials,
    "http://www.example.org:80",
    policy~,
  ).unwrap()
  let header = session
    .authorization(
      "http://www.example.org:80",
      Get,
      "/dir/index.html",
      rfc7616_cnonce,
    )
    .unwrap()
    .to_string_lossy()
  assert_eq(
    auth_test_quoted_parameter(header, "response"),
    Some("8ca523f5e9506fed4657c9700eebdbec"),
  )
}

///|
test "digest auth: RFC 7616 SHA-512-256 userhash vector with erratum 4897" {
  let challenge = auth_test_challenge(
    "Digest realm=\"api@example.org\", qop=\"auth\", " +
    "algorithm=SHA-512-256, " +
    "nonce=\"5TsQWLVdgBdmrQ0XsxbDODV+57QdFR34I9HAbC/RVvkK\", " +
    "opaque=\"HRPCssKJSGjCrkzDg8OhwpzCiGPChXYjwrI2QmXDnsOS\", " +
    "charset=UTF-8, userhash=true",
  )
  let session = @auth.DigestSession::new(
    challenge,
    @auth.DigestCredentials::new("J\u{e4}s\u{f8}n Doe", "Secret, or not?").unwrap(),
    "http://api.example.org:80",
  ).unwrap()
  let header = session
    .authorization(
      "http://api.example.org:80",
      Get,
      "/doe.json",
      "NTg6RKcb9boFIAS3KrFK9BGeh+iDa/sm6jUMp2wds69v",
    )
    .unwrap()
    .to_string_lossy()
  assert_eq(
    auth_test_quoted_parameter(header, "username"),
    Some("793263caabb707a56211940d90411ea4a575adeccb7e360aeb624ed06ece9b0b"),
  )
  assert_eq(
    auth_test_quoted_parameter(header, "response"),
    Some("3798d4131c277846293534c3edc11bd8a5e4cdcbff78b05db9d95eeb1cec68a5"),
  )
  assert_true(header.contains("userhash=true"))
}

///|
test "digest challenge: parser rejects ambiguity and unsupported parameters" {
  for
    invalid in [
      "Basic realm=\"x\"", "Digest nonce=\"n\", qop=\"auth\", algorithm=SHA-256",
      "Digest realm=\"r\", qop=\"auth\", algorithm=SHA-256", "Digest realm=\"r\", realm=\"other\", nonce=\"n\", qop=\"auth\", algorithm=SHA-256",
      "Digest realm=\"unterminated, nonce=\"n\"",
    ] {
    assert_true(@auth.DigestChallenge::parse_string(invalid) is Err(_))
  }
  assert_true(
    @auth.DigestChallenge::parse_string(
      "Digest realm=\"r\", nonce=\"n\", qop=\"unknown\", algorithm=SHA-256",
    )
    is Err(UnsupportedDigestQop),
  )
  assert_true(
    @auth.DigestChallenge::parse_string(
      "Digest realm=\"r\", nonce=\"n\", qop=\"auth\", algorithm=SHA-1",
    )
    is Err(UnsupportedDigestAlgorithm),
  )
  assert_true(
    @auth.DigestChallenge::parse_string(
      "Digest realm=\"r\", nonce=\"n\", qop=\"auth\", algorithm=SHA-256, charset=ISO-8859-1",
    )
    is Err(UnsupportedDigestCharset),
  )
}

///|
test "digest challenge: quoted escapes are parsed and re-escaped safely" {
  let challenge = auth_test_challenge(
    "Digest realm=\"quoted\\\"realm\", nonce=\"slash\\\\nonce\", " +
    "qop=\"auth\", algorithm=SHA-256",
  )
  let session = @auth.DigestSession::new(
    challenge,
    @auth.DigestCredentials::new("user", "password").unwrap(),
    "https://example.com:443",
  ).unwrap()
  let header = session
    .authorization("https://example.com:443", Get, "/", "cnonce")
    .unwrap()
    .to_string_lossy()
  assert_true(header.contains("realm=\"quoted\\\"realm\""))
  assert_true(header.contains("nonce=\"slash\\\\nonce\""))
}

///|
test "digest auth: auth-int requires a hash from the matching algorithm" {
  let challenge = auth_test_challenge(
    "Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\", algorithm=SHA-256",
  )
  let session = @auth.DigestSession::new(
    challenge,
    @auth.DigestCredentials::new("user", "password").unwrap(),
    "https://example.com:443",
  ).unwrap()
  assert_true(
    session.authorization("https://example.com:443", Post, "/upload", "cnonce")
    is Err(DigestEntityHashRequired),
  )
  assert_eq(session.nonce_count(), 0L)
  let wrong = @auth.DigestEntityHash::compute(DigestMd5, b"body")
  assert_true(
    session.authorization(
      "https://example.com:443",
      Post,
      "/upload",
      "cnonce",
      entity_hash=Some(wrong),
    )
    is Err(DigestEntityHashMismatch),
  )
  let entity = @auth.DigestEntityHash::compute(DigestSha256, b"body")
  let header = session
    .authorization(
      "https://example.com:443",
      Post,
      "/upload",
      "cnonce",
      entity_hash=Some(entity),
    )
    .unwrap()
    .to_string_lossy()
  assert_true(header.contains("qop=auth-int"))
  assert_eq(session.nonce_count(), 1L)
}

///|
test "digest auth: origin, target, nonce-count, and cnonce gates fail before mutation" {
  let challenge = auth_test_challenge(
    "Digest realm=\"r\", nonce=\"n\", qop=\"auth\", algorithm=SHA-256",
  )
  let policy = { ..@auth.DigestPolicy::defaults(), max_nonce_uses: 1L, }
  let session = @auth.DigestSession::new(
    challenge,
    @auth.DigestCredentials::new("user", "password").unwrap(),
    "https://example.com:443",
    policy~,
  ).unwrap()
  assert_true(
    session.authorization("https://other.example:443", Get, "/", "cnonce")
    is Err(DigestOriginMismatch),
  )
  assert_true(
    session.authorization(
      "https://example.com:443",
      Get,
      "/bad\r\ntarget",
      "cnonce",
    )
    is Err(InvalidDigestRequestUri),
  )
  assert_true(
    session.authorization("https://example.com:443", Get, "/", "bad cnonce")
    is Err(InvalidDigestCnonce),
  )
  assert_eq(session.nonce_count(), 0L)
  let first = session
    .authorization("https://example.com:443", Get, "/", "cnonce")
    .unwrap()
    .to_string_lossy()
  assert_true(first.contains("nc=00000001"))
  assert_true(
    session.authorization("https://example.com:443", Get, "/", "cnonce")
    is Err(DigestNonceCountExhausted),
  )
}

///|
test "digest auth: stale challenge replacement resets count but not realm scope" {
  let initial = auth_test_challenge(
    "Digest realm=\"r\", nonce=\"old\", qop=\"auth\", algorithm=SHA-256",
  )
  let session = @auth.DigestSession::new(
    initial,
    @auth.DigestCredentials::new("user", "password").unwrap(),
    "https://example.com:443",
  ).unwrap()
  session.authorization("https://example.com:443", Get, "/", "cnonce") |> ignore
  assert_eq(session.nonce_count(), 1L)
  let not_stale = auth_test_challenge(
    "Digest realm=\"r\", nonce=\"new\", qop=\"auth\", algorithm=SHA-256",
  )
  assert_eq(
    session.replace_stale_challenge(not_stale),
    Err(DigestChallengeNotStale),
  )
  let wrong_realm = auth_test_challenge(
    "Digest realm=\"other\", nonce=\"new\", stale=true, qop=\"auth\", algorithm=SHA-256",
  )
  assert_eq(
    session.replace_stale_challenge(wrong_realm),
    Err(DigestRealmChanged),
  )
  let stale = auth_test_challenge(
    "Digest realm=\"r\", nonce=\"new\", stale=true, qop=\"auth\", algorithm=SHA-256",
  )
  assert_eq(session.replace_stale_challenge(stale), Ok(()))
  assert_eq(session.nonce_count(), 0L)
}

///|
test "digest auth: selector skips locally denied downgrade challenges" {
  let md5 = auth_test_header(
    "Digest realm=\"r\", nonce=\"n\", qop=\"auth\", algorithm=MD5",
  )
  let sha = auth_test_header(
    "Digest realm=\"r\", nonce=\"n\", qop=\"auth\", algorithm=SHA-256",
  )
  assert_eq(
    @auth.select_digest_challenge([md5, sha]).unwrap().algorithm(),
    DigestSha256,
  )
}

///|
test "digest auth: legacy no-qop mode is disabled unless explicitly requested" {
  let challenge = auth_test_challenge(
    "Digest realm=\"testrealm@host.com\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", algorithm=MD5",
  )
  let credentials = @auth.DigestCredentials::new("Mufasa", "Circle Of Life").unwrap()
  let denied = { ..@auth.DigestPolicy::defaults(), allow_md5: true, }
  assert_true(
    @auth.DigestSession::new(
      challenge,
      credentials,
      "http://example.com:80",
      policy=denied,
    )
    is Err(UnsupportedDigestQop),
  )
  let allowed = { ..denied, allow_legacy_no_qop: true, }
  let session = @auth.DigestSession::new(
    challenge,
    credentials,
    "http://example.com:80",
    policy=allowed,
  ).unwrap()
  let header = session
    .authorization(
      "http://example.com:80",
      Get,
      "/dir/index.html",
      "legacy-cnonce",
    )
    .unwrap()
    .to_string_lossy()
  assert_true(header.contains("response=\"670fd8c2df070c60b045671b8b24ff02\""))
  assert_true(!header.contains("qop="))
  assert_true(!header.contains("nc="))
}

///|
test "digest auth info: verifies RFC response state before adopting nextnonce" {
  let session = @auth.DigestSession::new(
    rfc7616_challenge("SHA-256"),
    @auth.DigestCredentials::new("Mufasa", "Circle of Life").unwrap(),
    "http://www.example.org:80",
  ).unwrap()
  let authorization = session
    .authorize(
      "http://www.example.org:80",
      Get,
      "/dir/index.html",
      rfc7616_cnonce,
    )
    .unwrap()
  assert_true(authorization.header().to_string_lossy().contains("nc=00000001"))
  let info = session
    .verify_authentication_info(
      authorization,
      auth_test_header(
        "rspauth=\"86d3b25618d41854ca5039a5d7e53ff6355d5134a9b1fb088a78ac3c462195a0\", " +
        "cnonce=\"" +
        rfc7616_cnonce +
        "\", nc=00000001, qop=auth, nextnonce=\"replacement\"",
      ),
    )
    .unwrap()
  assert_true(info.response_authenticated())
  assert_eq(info.next_nonce(), Some("replacement"))
  assert_eq(session.nonce_count(), 0L)
  let next = session
    .authorization(
      "http://www.example.org:80",
      Get,
      "/dir/index.html",
      "next-cnonce",
    )
    .unwrap()
    .to_string_lossy()
  assert_true(next.contains("nonce=\"replacement\""))
  assert_true(next.contains("nc=00000001"))
}

///|
test "digest auth info: rejects tampering, missing proof, and request mismatch" {
  let session = @auth.DigestSession::new(
    rfc7616_challenge("SHA-256"),
    @auth.DigestCredentials::new("Mufasa", "Circle of Life").unwrap(),
    "http://www.example.org:80",
  ).unwrap()
  let authorization = session
    .authorize(
      "http://www.example.org:80",
      Get,
      "/dir/index.html",
      rfc7616_cnonce,
    )
    .unwrap()
  assert_true(
    authorization.verify_authentication_info(
      auth_test_header(
        "rspauth=\"06d3b25618d41854ca5039a5d7e53ff6355d5134a9b1fb088a78ac3c462195a0\", " +
        "cnonce=\"" +
        rfc7616_cnonce +
        "\", nc=00000001, qop=auth",
      ),
    )
    is Err(DigestResponseAuthMismatch),
  )
  assert_true(
    authorization.verify_authentication_info(
      auth_test_header("nextnonce=\"new\""),
    )
    is Err(MissingDigestResponseAuth),
  )
  assert_true(
    authorization.verify_authentication_info(
      auth_test_header(
        "rspauth=\"86d3b25618d41854ca5039a5d7e53ff6355d5134a9b1fb088a78ac3c462195a0\", " +
        "cnonce=\"wrong\", nc=00000001, qop=auth",
      ),
    )
    is Err(DigestAuthenticationContextMismatch),
  )
  assert_eq(session.nonce_count(), 1L)
}

///|
test "digest auth info: auth-int authenticates the decoded response entity" {
  let challenge = auth_test_challenge(
    "Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\", algorithm=SHA-256",
  )
  let session = @auth.DigestSession::new(
    challenge,
    @auth.DigestCredentials::new("user", "password").unwrap(),
    "https://example.com:443",
  ).unwrap()
  let request_hash = @auth.DigestEntityHash::compute(
    DigestSha256,
    b"request body",
  )
  let authorization = session
    .authorize(
      "https://example.com:443",
      Post,
      "/upload",
      "cnonce",
      entity_hash=Some(request_hash),
    )
    .unwrap()
  let header = auth_test_header(
    "rspauth=\"10673ef43d15cdbcdbeabb81104d11bc8042725b25dc89b3dc63fc7d17fc3198\", " +
    "cnonce=\"cnonce\", nc=00000001, qop=auth-int",
  )
  assert_true(
    authorization.verify_authentication_info(header)
    is Err(DigestEntityHashRequired),
  )
  let response_hash = @auth.DigestEntityHash::compute(
    DigestSha256,
    b"response body",
  )
  assert_true(
    authorization.verify_authentication_info(
      header,
      response_entity_hash=Some(response_hash),
    )
    is Ok(_),
  )
}

///|
test "digest auth info: concurrent nextnonce cannot overwrite newer state" {
  let session = @auth.DigestSession::new(
    rfc7616_challenge("SHA-256"),
    @auth.DigestCredentials::new("Mufasa", "Circle of Life").unwrap(),
    "http://www.example.org:80",
  ).unwrap()
  let first = session
    .authorize(
      "http://www.example.org:80",
      Get,
      "/dir/index.html",
      rfc7616_cnonce,
    )
    .unwrap()
  session.authorization(
    "http://www.example.org:80",
    Get,
    "/second",
    "second-cnonce",
  )
  |> ignore
  let response = auth_test_header(
    "rspauth=\"86d3b25618d41854ca5039a5d7e53ff6355d5134a9b1fb088a78ac3c462195a0\", " +
    "cnonce=\"" +
    rfc7616_cnonce +
    "\", nc=00000001, qop=auth, nextnonce=\"racing\"",
  )
  assert_true(
    session.verify_authentication_info(first, response)
    is Err(DigestNextNonceRace),
  )
  assert_eq(session.nonce_count(), 2L)
}

///|
test "digest auth info: parser rejects duplicate, malformed, and uppercase proofs" {
  let session = @auth.DigestSession::new(
    rfc7616_challenge("SHA-256"),
    @auth.DigestCredentials::new("Mufasa", "Circle of Life").unwrap(),
    "http://www.example.org:80",
  ).unwrap()
  let authorization = session
    .authorize(
      "http://www.example.org:80",
      Get,
      "/dir/index.html",
      rfc7616_cnonce,
    )
    .unwrap()
  for
    value in [
      "rspauth=\"x\", rspauth=\"x\"", "rspauth=unterminated space", "rspauth=\"86D3B25618D41854CA5039A5D7E53FF6355D5134A9B1FB088A78AC3C462195A0\", cnonce=\"f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ\", nc=00000001, qop=auth",
    ] {
    assert_true(
      authorization.verify_authentication_info(auth_test_header(value))
      is Err(_),
    )
  }
}
