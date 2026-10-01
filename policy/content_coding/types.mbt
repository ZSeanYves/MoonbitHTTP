///|
pub(all) enum ContentCoding {
  Identity
  Gzip
  Deflate
  Brotli
} derive(Eq, Debug)

///|
pub(all) enum DecodeStatus {
  DecodeNeedInput
  DecodeNeedOutput
  DecodeDone
} derive(Eq, Debug)

///|
pub(all) struct DecodeStep {
  consumed : Int
  output : Bytes
  status : DecodeStatus
} derive(Eq, Debug)

///|
pub(all) suberror ContentCodingError {
  InvalidContentCodingLimits
  InvalidContentEncoding
  UnsupportedContentCoding(String)
  TooManyContentCodings(Int)
  EncodedBodyLimitExceeded(Int)
  DecodedBodyLimitExceeded(Int)
  TruncatedEncodedBody(ContentCoding)
  InvalidEncodedBody(ContentCoding)
  TrailingEncodedData(ContentCoding)
  DecoderAlreadyFinished(ContentCoding)
  DecoderStalled(ContentCoding)
  DecoderInputPending
} derive(Eq, Debug)

///|
pub(all) struct ContentCodingLimits {
  max_encoded_bytes : Int
  max_decoded_bytes : Int
  max_codings : Int
  output_chunk_bytes : Int
} derive(Eq, Debug)

///|
pub fn ContentCodingLimits::from_http_limits(
  limits : @types.Limits,
  max_codings? : Int = 4,
  output_chunk_bytes? : Int = 8192,
) -> Result[ContentCodingLimits, ContentCodingError] {
  match limits.validate() {
    Ok(_) => ()
    Err(_) => return Err(InvalidContentCodingLimits)
  }
  let result = {
    max_encoded_bytes: limits.max_body_bytes,
    max_decoded_bytes: limits.max_body_bytes,
    max_codings,
    output_chunk_bytes,
  }
  match result.validate() {
    Ok(_) => Ok(result)
    Err(error) => Err(error)
  }
}

///|
pub fn ContentCodingLimits::defaults() -> ContentCodingLimits {
  {
    max_encoded_bytes: 16 * 1024 * 1024,
    max_decoded_bytes: 16 * 1024 * 1024,
    max_codings: 4,
    output_chunk_bytes: 8192,
  }
}

///|
pub fn ContentCodingLimits::validate(
  self : ContentCodingLimits,
) -> Result[Unit, ContentCodingError] {
  if self.max_encoded_bytes < 0 ||
    self.max_decoded_bytes < 0 ||
    self.max_codings < 1 ||
    self.output_chunk_bytes < 1 ||
    self.output_chunk_bytes > 1024 * 1024 {
    Err(InvalidContentCodingLimits)
  } else {
    Ok(())
  }
}
