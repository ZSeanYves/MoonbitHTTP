///|
#derive(Debug, Eq)
pub(all) suberror InjectedIoError {
  InjectedReadFailure
  InjectedWriteFailure
}

///|
pub fn fragment(input : BytesView, sizes : Array[Int32]) -> Array[Bytes] {
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
pub struct FaultReader {
  reader_controller : @aio.BinaryReaderController
  chunks : Array[Bytes]
  mut chunk_index : Int32
  mut chunk_offset : Int32
  mut reads : Int32
  fail_after : Int32?
}

///|
pub fn FaultReader::new(
  chunks : Array[Bytes],
  fail_after~ : Int32? = None,
) -> FaultReader {
  {
    reader_controller: BinaryReaderController(),
    chunks,
    chunk_index: 0,
    chunk_offset: 0,
    reads: 0,
    fail_after,
  }
}

///|
pub impl @aio.BinaryReader for FaultReader

///|
impl @aio.BinaryReaderImpl for FaultReader with fn name(_self) {
  "FaultReader"
}

///|
impl @aio.BinaryReaderImpl for FaultReader with fn get_controller(self) {
  self.reader_controller
}

///|
impl @aio.BinaryReaderImpl for FaultReader with fn raw_read_impl(
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
  writer_controller : @aio.BinaryWriterController
  bytes : Array[Byte]
  mut writes : Int32
  fail_after : Int32?
}

///|
pub fn RecordingWriter::new(fail_after~ : Int32? = None) -> RecordingWriter {
  {
    writer_controller: BinaryWriterController(),
    bytes: [],
    writes: 0,
    fail_after,
  }
}

///|
pub impl @aio.BinaryWriter for RecordingWriter

///|
impl @aio.BinaryWriterImpl for RecordingWriter with fn name(_self) {
  "RecordingWriter"
}

///|
impl @aio.BinaryWriterImpl for RecordingWriter with fn get_controller(self) {
  self.writer_controller
}

///|
impl @aio.BinaryWriterImpl for RecordingWriter with fn flush_partial_data(_self) {
  ()
}

///|
impl @aio.BinaryWriterImpl for RecordingWriter with fn raw_write_impl(
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
