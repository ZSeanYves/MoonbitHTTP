///|
pub(all) suberror InjectedIoError {
  InjectedReadFailure
  InjectedWriteFailure
} derive(Debug, Eq)

///|
pub fn fragment(input : BytesView, sizes : Array[Int]) -> Array[Bytes] {
  let chunks : Array[Bytes] = []
  let mut offset = 0
  for size in sizes {
    if offset >= input.length() {
      break
    }
    let end = (offset + size.max(0)).min(input.length())
    if end > offset {
      chunks.push(input[offset:end].to_owned())
    }
    offset = end
  }
  if offset < input.length() {
    chunks.push(input[offset:].to_owned())
  }
  chunks
}

///|
#warnings("-alert_internal")
pub struct FaultReader {
  reader_buffer : @aio.ReaderBuffer
  chunks : Array[Bytes]
  mut chunk_index : Int
  mut chunk_offset : Int
  mut reads : Int
  fail_after : Int?
}

///|
#warnings("-alert_internal")
pub fn FaultReader::new(
  chunks : Array[Bytes],
  fail_after? : Int? = None,
) -> FaultReader {
  {
    reader_buffer: @aio.ReaderBuffer::new(),
    chunks,
    chunk_index: 0,
    chunk_offset: 0,
    reads: 0,
    fail_after,
  }
}

///|
#warnings("-alert_internal")
pub impl @aio.Reader for FaultReader with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
pub impl @aio.Reader for FaultReader with fn _direct_read(
  self,
  destination,
  offset~,
  max_len~,
) {
  if self.fail_after is Some(limit) && self.reads >= limit {
    raise InjectedReadFailure
  }
  self.reads += 1
  if self.chunk_index >= self.chunks.length() {
    return 0
  }
  let chunk = self.chunks[self.chunk_index]
  let count = (chunk.length() - self.chunk_offset).min(max_len)
  for i in 0..<count {
    destination[offset + i] = chunk[self.chunk_offset + i]
  }
  self.chunk_offset += count
  if self.chunk_offset == chunk.length() {
    self.chunk_index += 1
    self.chunk_offset = 0
  }
  count
}

///|
pub struct RecordingWriter {
  bytes : Array[Byte]
  mut writes : Int
  fail_after : Int?
}

///|
pub fn RecordingWriter::new(fail_after? : Int? = None) -> RecordingWriter {
  { bytes: [], writes: 0, fail_after }
}

///|
pub impl @aio.Writer for RecordingWriter with fn write_once(
  self,
  source,
  offset~,
  len~,
) {
  if self.fail_after is Some(limit) && self.writes >= limit {
    raise InjectedWriteFailure
  }
  self.writes += 1
  for i in offset..<(offset + len) {
    self.bytes.push(source[i])
  }
  len
}

///|
pub fn RecordingWriter::contents(self : RecordingWriter) -> Bytes {
  Bytes::from_array(self.bytes)
}
