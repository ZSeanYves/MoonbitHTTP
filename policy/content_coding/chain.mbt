///|
pub(all) enum ContentDecodePoll {
  ContentDecodeNeedInput
  ContentDecoded(Bytes)
  ContentDecodeDone
} derive(Eq, Debug)

///|
priv enum StagePoll {
  StageOutput(Bytes, Bool)
  StageNeedInput
  StageDone
}

///|
/// A pull-driven decoding pipeline. Sender-applied codings are decoded in
/// reverse order and each stage retains at most one bounded hand-off chunk.
pub struct ContentDecoderChain {
  decoders : Array[ContentDecoder]
  pending : Array[Bytes?]
  offsets : Array[Int]
  upstream_done : Array[Bool]
  statuses : Array[DecodeStatus]
  mut awaiting_input : Bool
  mut finished : Bool
  mut failure : ContentCodingError?
}

///|
pub fn ContentDecoderChain::new(
  codings : Array[ContentCoding],
  limits? : ContentCodingLimits = ContentCodingLimits::defaults(),
) -> Result[ContentDecoderChain, ContentCodingError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if codings.length() > limits.max_codings {
    return Err(TooManyContentCodings(limits.max_codings))
  }
  let decode_order = if codings.is_empty() {
    [Identity]
  } else {
    let result : Array[ContentCoding] = []
    for index = codings.length() - 1; index >= 0; index = index - 1 {
      result.push(codings[index])
    }
    result
  }
  let decoders : Array[ContentDecoder] = []
  for index, coding in decode_order {
    let stage_limits = if index == 0 {
      limits
    } else {
      { ..limits, max_encoded_bytes: limits.max_decoded_bytes, }
    }
    let decoder = match ContentDecoder::new(coding, limits=stage_limits) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    decoders.push(decoder)
  }
  let count = decoders.length()
  Ok({
    decoders,
    pending: Array::make(count, None),
    offsets: Array::make(count, 0),
    upstream_done: Array::make(count, false),
    statuses: Array::make(count, DecodeNeedInput),
    awaiting_input: true,
    finished: false,
    failure: None,
  })
}

///|
fn ContentDecoderChain::fail(
  self : ContentDecoderChain,
  error : ContentCodingError,
) -> Result[ContentDecodePoll, ContentCodingError] {
  if self.failure is None {
    self.failure = Some(error)
  }
  Err(error)
}

///|
/// Supplies the next encoded body fragment after `poll` reports
/// `ContentDecodeNeedInput`. `end=true` permanently closes encoded input.
pub fn ContentDecoderChain::feed(
  self : ContentDecoderChain,
  input : BytesView,
  end? : Bool = false,
) -> Result[Unit, ContentCodingError] {
  match self.failure {
    Some(error) => return Err(error)
    None => ()
  }
  if self.finished {
    return Err(DecoderAlreadyFinished(Identity))
  }
  if !self.awaiting_input || self.pending[0] is Some(_) {
    return Err(DecoderInputPending)
  }
  if !input.is_empty() {
    self.pending[0] = Some(input.to_owned())
  }
  if end {
    self.upstream_done[0] = true
  }
  self.awaiting_input = false
  Ok(())
}

///|
fn ContentDecoderChain::step_stage_input(
  self : ContentDecoderChain,
  index : Int,
  input : BytesView,
) -> Result[StagePoll, ContentCodingError] {
  let result = match
    self.decoders[index].step(input, end=self.upstream_done[index]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.consumed < 0 || result.consumed > input.length() {
    return Err(DecoderStalled(self.decoders[index].coding))
  }
  self.statuses[index] = result.status
  match self.pending[index] {
    Some(value) => {
      self.offsets[index] += result.consumed
      if self.offsets[index] == value.length() {
        self.pending[index] = None
        self.offsets[index] = 0
      }
    }
    None => ()
  }
  if !result.output.is_empty() {
    return Ok(StageOutput(result.output, result.status == DecodeDone))
  }
  if result.status == DecodeDone {
    return Ok(StageDone)
  }
  if result.consumed == 0 && !input.is_empty() {
    return Err(DecoderStalled(self.decoders[index].coding))
  }
  self.poll_stage(index)
}

///|
fn ContentDecoderChain::poll_stage(
  self : ContentDecoderChain,
  index : Int,
) -> Result[StagePoll, ContentCodingError] {
  if self.statuses[index] == DecodeDone {
    return Ok(StageDone)
  }
  match self.pending[index] {
    Some(value) => {
      let offset = self.offsets[index]
      return self.step_stage_input(index, value[offset:])
    }
    None => ()
  }
  if self.statuses[index] == DecodeNeedOutput || self.upstream_done[index] {
    return self.step_stage_input(index, b"")
  }
  if index == 0 {
    self.awaiting_input = true
    return Ok(StageNeedInput)
  }
  match self.poll_stage(index - 1) {
    Err(error) => Err(error)
    Ok(StageNeedInput) => Ok(StageNeedInput)
    Ok(StageDone) => {
      self.upstream_done[index] = true
      self.poll_stage(index)
    }
    Ok(StageOutput(output, done_after)) => {
      self.pending[index] = Some(output)
      self.offsets[index] = 0
      if done_after {
        self.upstream_done[index] = true
      }
      self.poll_stage(index)
    }
  }
}

///|
/// Drives the pipeline until it produces one bounded plaintext chunk, needs
/// another encoded fragment, completes, or returns a stable typed error.
pub fn ContentDecoderChain::poll(
  self : ContentDecoderChain,
) -> Result[ContentDecodePoll, ContentCodingError] {
  match self.failure {
    Some(error) => return Err(error)
    None => ()
  }
  if self.finished {
    return Ok(ContentDecodeDone)
  }
  let final_stage = self.decoders.length() - 1
  match self.poll_stage(final_stage) {
    Ok(StageOutput(output, _)) => Ok(ContentDecoded(output))
    Ok(StageNeedInput) => Ok(ContentDecodeNeedInput)
    Ok(StageDone) => {
      self.finished = true
      Ok(ContentDecodeDone)
    }
    Err(error) => self.fail(error)
  }
}
