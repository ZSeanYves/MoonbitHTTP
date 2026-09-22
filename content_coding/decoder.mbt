///|
pub struct BrotliSink {
  chunks : Array[Bytes]
  mut chunk_index : Int
  mut chunk_offset : Int
  mut final_seen : Bool
}

///|
fn BrotliSink::take(self : BrotliSink, maximum : Int) -> Bytes? {
  while self.chunk_index < self.chunks.length() {
    let chunk = self.chunks[self.chunk_index]
    if self.chunk_offset == chunk.length() {
      self.chunk_index += 1
      self.chunk_offset = 0
      continue
    }
    let amount = (chunk.length() - self.chunk_offset).min(maximum)
    let result = chunk[self.chunk_offset:self.chunk_offset + amount].to_owned()
    self.chunk_offset += amount
    if self.chunk_index == self.chunks.length() - 1 &&
      self.chunk_offset == chunk.length() {
      self.chunks.clear()
      self.chunk_index = 0
      self.chunk_offset = 0
    }
    return Some(result)
  }
  self.chunks.clear()
  self.chunk_index = 0
  self.chunk_offset = 0
  None
}

///|
fn BrotliSink::has_output(self : BrotliSink) -> Bool {
  self.chunk_index < self.chunks.length()
}

///|
pub enum DecoderBackend {
  IdentityDecoder
  GzipDecoder(@gzip.Decoder)
  ZlibDecoder(@zlib.Decoder)
  BrotliDecoder(@fbr.UnbrotliStream, BrotliSink)
}

///|
/// A bounded, incremental decoder for one HTTP content coding.
pub struct ContentDecoder {
  coding : ContentCoding
  backend : DecoderBackend
  limits : ContentCodingLimits
  mut encoded_bytes : Int
  mut decoded_bytes : Int
  mut finished : Bool
  mut input_ended : Bool
  mut failure : ContentCodingError?
}

///|
pub fn ContentDecoder::new(
  coding : ContentCoding,
  limits? : ContentCodingLimits = ContentCodingLimits::defaults(),
) -> Result[ContentDecoder, ContentCodingError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let backend = match coding {
    Identity => IdentityDecoder
    Gzip => GzipDecoder(Decoder())
    Deflate => ZlibDecoder(Decoder())
    Brotli => {
      let sink : BrotliSink = {
        chunks: [],
        chunk_index: 0,
        chunk_offset: 0,
        final_seen: false,
      }
      let decoder = @fbr.UnbrotliStream::new(opts={
        ..@fbr.UnbrotliOptions::default(),
        max_input_size: limits.max_encoded_bytes,
        max_output_size: limits.max_decoded_bytes,
      })
      decoder.set_ondata(fn(data, final_) {
        if !data.is_empty() {
          sink.chunks.push(Bytes::from_array(data))
        }
        if final_ {
          sink.final_seen = true
        }
      })
      BrotliDecoder(decoder, sink)
    }
  }
  Ok({
    coding,
    backend,
    limits,
    encoded_bytes: 0,
    decoded_bytes: 0,
    finished: false,
    input_ended: false,
    failure: None,
  })
}

///|
pub fn ContentDecoder::encoded_bytes(self : ContentDecoder) -> Int {
  self.encoded_bytes
}

///|
pub fn ContentDecoder::decoded_bytes(self : ContentDecoder) -> Int {
  self.decoded_bytes
}

///|
pub fn ContentDecoder::is_finished(self : ContentDecoder) -> Bool {
  self.finished
}

///|
fn ContentDecoder::fail(
  self : ContentDecoder,
  error : ContentCodingError,
) -> Result[DecodeStep, ContentCodingError] {
  if self.failure is None {
    self.failure = Some(error)
  }
  Err(error)
}

///|
fn ContentDecoder::record_output(
  self : ContentDecoder,
  consumed : Int,
  output : Bytes,
  status : DecodeStatus,
) -> Result[DecodeStep, ContentCodingError] {
  if output.length() > self.limits.max_decoded_bytes - self.decoded_bytes {
    return self.fail(DecodedBodyLimitExceeded(self.limits.max_decoded_bytes))
  }
  self.encoded_bytes += consumed
  self.decoded_bytes += output.length()
  if status == DecodeDone {
    self.finished = true
  }
  if consumed == 0 && output.is_empty() && status == DecodeNeedOutput {
    return self.fail(DecoderStalled(self.coding))
  }
  Ok({ consumed, output, status, })
}

///|
fn ContentDecoder::offered_length(
  self : ContentDecoder,
  input_length : Int,
) -> Result[Int, ContentCodingError] {
  let remaining = self.limits.max_encoded_bytes - self.encoded_bytes
  if input_length > 0 && remaining == 0 {
    Err(EncodedBodyLimitExceeded(self.limits.max_encoded_bytes))
  } else {
    Ok(input_length.min(remaining))
  }
}

///|
fn flate_decode_status(status : @flate.Status) -> DecodeStatus {
  match status {
    Done => DecodeDone
    NeedMoreInput => DecodeNeedInput
    NeedMoreOutput => DecodeNeedOutput
  }
}

///|
fn decode_output_capacity(remaining : Int, preferred : Int) -> Int {
  if remaining < preferred {
    remaining + 1
  } else {
    preferred
  }
}

///|
fn ContentDecoder::step_identity(
  self : ContentDecoder,
  input : BytesView,
  end : Bool,
) -> Result[DecodeStep, ContentCodingError] {
  let offered = match self.offered_length(input.length()) {
    Ok(value) => value
    Err(error) => return self.fail(error)
  }
  let remaining_output = self.limits.max_decoded_bytes - self.decoded_bytes
  let consumed = offered.min(self.limits.output_chunk_bytes)
  if consumed > remaining_output {
    return self.fail(DecodedBodyLimitExceeded(self.limits.max_decoded_bytes))
  }
  let status = if end && consumed == input.length() {
    DecodeDone
  } else if consumed < input.length() {
    DecodeNeedOutput
  } else {
    DecodeNeedInput
  }
  self.record_output(consumed, input[:consumed].to_owned(), status)
}

///|
fn ContentDecoder::step_gzip(
  self : ContentDecoder,
  decoder : @gzip.Decoder,
  input : BytesView,
  end : Bool,
) -> Result[DecodeStep, ContentCodingError] {
  let offered = match self.offered_length(input.length()) {
    Ok(value) => value
    Err(error) => return self.fail(error)
  }
  let remaining_output = self.limits.max_decoded_bytes - self.decoded_bytes
  let capacity = decode_output_capacity(
    remaining_output,
    self.limits.output_chunk_bytes,
  )
  let output = FixedArray::make(capacity.max(1), b'\x00')
  let status = decoder.step(
    input[:offered],
    output.mut_view(),
    end=end && offered == input.length(),
  ) catch {
    GzipError(Truncated, _) => return self.fail(TruncatedEncodedBody(Gzip))
    _ => return self.fail(InvalidEncodedBody(Gzip))
  }
  let consumed = decoder.last_consumed()
  let produced = decoder.last_produced()
  if status == Done &&
    (consumed < input.length() || !decoder.unused_input().is_empty()) {
    return self.fail(TrailingEncodedData(Gzip))
  }
  self.record_output(
    consumed,
    Bytes::from_array(output[:produced]),
    flate_decode_status(status),
  )
}

///|
fn ContentDecoder::step_zlib(
  self : ContentDecoder,
  decoder : @zlib.Decoder,
  input : BytesView,
  end : Bool,
) -> Result[DecodeStep, ContentCodingError] {
  let offered = match self.offered_length(input.length()) {
    Ok(value) => value
    Err(error) => return self.fail(error)
  }
  let remaining_output = self.limits.max_decoded_bytes - self.decoded_bytes
  let capacity = decode_output_capacity(
    remaining_output,
    self.limits.output_chunk_bytes,
  )
  let output = FixedArray::make(capacity.max(1), b'\x00')
  let status = decoder.step(
    input[:offered],
    output.mut_view(),
    end=end && offered == input.length(),
  ) catch {
    ZlibError(Truncated, _) => return self.fail(TruncatedEncodedBody(Deflate))
    ZlibError(TrailingData, _) => return self.fail(TrailingEncodedData(Deflate))
    _ => return self.fail(InvalidEncodedBody(Deflate))
  }
  let consumed = decoder.last_consumed()
  let produced = decoder.last_produced()
  if status == Done &&
    (consumed < input.length() || !decoder.unused_input().is_empty()) {
    return self.fail(TrailingEncodedData(Deflate))
  }
  self.record_output(
    consumed,
    Bytes::from_array(output[:produced]),
    flate_decode_status(status),
  )
}

///|
fn ContentDecoder::step_brotli(
  self : ContentDecoder,
  decoder : @fbr.UnbrotliStream,
  sink : BrotliSink,
  input : BytesView,
  end : Bool,
) -> Result[DecodeStep, ContentCodingError] {
  match sink.take(self.limits.output_chunk_bytes) {
    Some(output) => {
      let status = if sink.final_seen && !sink.has_output() {
        DecodeDone
      } else {
        DecodeNeedOutput
      }
      return self.record_output(0, output, status)
    }
    None => ()
  }
  let offered = match self.offered_length(input.length()) {
    Ok(value) => value
    Err(error) => return self.fail(error)
  }
  if self.input_ended && offered > 0 {
    return self.fail(TrailingEncodedData(Brotli))
  }
  let final_input = end && offered == input.length()
  let pushed : Result[Unit, ContentCodingError] = try {
    decoder.push(input[:offered].to_fixedarray(), final_=final_input)
    Ok(())
  } catch {
    FbrError(code=UnexpectedEOF, ..) => Err(TruncatedEncodedBody(Brotli))
    FbrError(code=InvalidZipData, ..) =>
      Err(DecodedBodyLimitExceeded(self.limits.max_decoded_bytes))
    _ => Err(InvalidEncodedBody(Brotli))
  }
  match pushed {
    Err(error) => return self.fail(error)
    Ok(_) => ()
  }
  if final_input {
    self.input_ended = true
  }
  let output = sink.take(self.limits.output_chunk_bytes).unwrap_or(b"")
  let status = if sink.final_seen && !sink.has_output() {
    DecodeDone
  } else if sink.has_output() {
    DecodeNeedOutput
  } else {
    DecodeNeedInput
  }
  self.record_output(offered, output, status)
}

///|
/// Advances one content decoder without performing I/O. Output is capped to
/// `output_chunk_bytes`; callers re-present any unconsumed input suffix.
pub fn ContentDecoder::step(
  self : ContentDecoder,
  input : BytesView,
  end? : Bool = false,
) -> Result[DecodeStep, ContentCodingError] {
  match self.failure {
    Some(error) => return Err(error)
    None => ()
  }
  if self.finished {
    if input.is_empty() {
      return Ok({ consumed: 0, output: b"", status: DecodeDone, })
    }
    return self.fail(DecoderAlreadyFinished(self.coding))
  }
  match self.backend {
    IdentityDecoder => self.step_identity(input, end)
    GzipDecoder(decoder) => self.step_gzip(decoder, input, end)
    ZlibDecoder(decoder) => self.step_zlib(decoder, input, end)
    BrotliDecoder(decoder, sink) => self.step_brotli(decoder, sink, input, end)
  }
}
