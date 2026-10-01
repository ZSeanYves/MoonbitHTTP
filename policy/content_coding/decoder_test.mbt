///|
fn content_test_collect(
  codings : Array[@content_coding.ContentCoding],
  encoded : Bytes,
  limits : @content_coding.ContentCodingLimits,
  split_size? : Int = 3,
) -> Result[Bytes, @content_coding.ContentCodingError] {
  let chain = match @content_coding.ContentDecoderChain::new(codings, limits~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output : Array[Byte] = []
  let mut offset = 0
  for ;; {
    match chain.poll() {
      Err(error) => return Err(error)
      Ok(ContentDecoded(chunk)) =>
        for byte in chunk {
          output.push(byte)
        }
      Ok(ContentDecodeDone) => return Ok(Bytes::from_array(output))
      Ok(ContentDecodeNeedInput) =>
        if offset == encoded.length() {
          match chain.feed(b"", end=true) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
        } else {
          let end = (offset + split_size).min(encoded.length())
          let final_ = end == encoded.length()
          match chain.feed(encoded[offset:end], end=final_) {
            Ok(_) => offset = end
            Err(error) => return Err(error)
          }
        }
    }
  } nobreak {
    Err(DecoderStalled(Identity))
  }
}

///|
fn content_test_limits(
  max_encoded : Int,
  max_decoded : Int,
) -> @content_coding.ContentCodingLimits {
  {
    max_encoded_bytes: max_encoded,
    max_decoded_bytes: max_decoded,
    max_codings: 4,
    output_chunk_bytes: 7,
  }
}

///|
test "content coding: parser preserves application order and rejects ambiguity" {
  let headers = @types.HeaderMap::new()
  headers.append_string("Content-Encoding", "GZip, deflate").unwrap()
  headers.append_string("Content-Encoding", "br").unwrap()
  assert_eq(
    @content_coding.parse_content_codings(headers),
    Ok([Gzip, Deflate, Brotli]),
  )
  let unsupported = @types.HeaderMap::new()
  unsupported.append_string("content-encoding", "compress").unwrap()
  assert_eq(
    @content_coding.parse_content_codings(unsupported),
    Err(UnsupportedContentCoding("compress")),
  )
  let invalid = @types.HeaderMap::new()
  invalid.append_string("content-encoding", ", ,").unwrap()
  assert_eq(
    @content_coding.parse_content_codings(invalid),
    Err(InvalidContentEncoding),
  )
  assert_eq(
    @content_coding.parse_content_codings(headers, max_codings=2),
    Err(TooManyContentCodings(2)),
  )
}

///|
test "content coding: gzip and deflate decode across every byte boundary" {
  let original = b"incremental content decoding must preserve every byte"
  let limits = content_test_limits(4096, 4096)
  let cases : Array[(@content_coding.ContentCoding, Bytes)] = [
    (Gzip, @gzip.gzip_compress(original)),
    (Deflate, @zlib.zlib_compress(original)),
  ]
  for entry in cases {
    let (coding, encoded) = entry
    assert_eq(
      content_test_collect([coding], encoded, limits, split_size=1),
      Ok(original),
    )
  }
}

///|
test "content coding: Brotli is incremental and bounded" {
  let original = b"brotli response body split into small transport fragments"
  let compressed = Bytes::from_array(@fbr.brotli_sync(original.to_fixedarray()))
  assert_eq(
    content_test_collect(
      [Brotli],
      compressed,
      content_test_limits(4096, 4096),
      split_size=2,
    ),
    Ok(original),
  )
}

///|
test "content coding: stacked encodings are removed in reverse order" {
  let original = b"first gzip, then zlib on the wire"
  let gzip = @gzip.gzip_compress(original)
  let encoded = @zlib.zlib_compress(gzip)
  assert_eq(
    content_test_collect(
      [Gzip, Deflate],
      encoded,
      content_test_limits(4096, 4096),
      split_size=1,
    ),
    Ok(original),
  )
}

///|
test "content coding: malformed, truncated, and trailing streams fail closed" {
  let limits = content_test_limits(4096, 4096)
  assert_true(
    content_test_collect([Gzip], b"not-gzip!!", limits)
    is Err(InvalidEncodedBody(Gzip)),
  )
  let valid = @gzip.gzip_compress(b"payload")
  assert_true(
    content_test_collect([Gzip], valid[:valid.length() - 1].to_owned(), limits)
    is Err(TruncatedEncodedBody(Gzip)),
  )
  let trailing = valid.to_array()
  trailing.push(b'x')
  assert_true(
    content_test_collect([Gzip], Bytes::from_array(trailing), limits)
    is Err(TrailingEncodedData(Gzip)),
  )
}

///|
test "content coding: encoded and decoded byte limits stop compression bombs" {
  let large = FixedArray::make(4096, b'a').unsafe_reinterpret_as_bytes()
  let compressed = @gzip.gzip_compress(large)
  assert_eq(
    content_test_collect(
      [Gzip],
      compressed,
      content_test_limits(compressed.length() - 1, 8192),
    ),
    Err(EncodedBodyLimitExceeded(compressed.length() - 1)),
  )
  assert_eq(
    content_test_collect(
      [Gzip],
      compressed,
      content_test_limits(4096, 128),
      split_size=1,
    ),
    Err(DecodedBodyLimitExceeded(128)),
  )
}

///|
test "content coding: each public step emits no more than configured chunk size" {
  let original = FixedArray::make(100, b'z').unsafe_reinterpret_as_bytes()
  let compressed = @zlib.zlib_compress(original)
  let limits = content_test_limits(4096, 4096)
  let decoder = @content_coding.ContentDecoder::new(Deflate, limits~).unwrap()
  let mut offset = 0
  for ;; {
    let step = decoder.step(compressed[offset:], end=true).unwrap()
    assert_true(step.output.length() <= limits.output_chunk_bytes)
    offset += step.consumed
    if step.status == DecodeDone {
      break
    }
  }
  assert_eq(offset, compressed.length())
  assert_eq(decoder.decoded_bytes(), original.length())
}
