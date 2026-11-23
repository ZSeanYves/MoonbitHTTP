///|
/// Return at most the caller's limit in one read, including buffered bytes.
pub async fn[R : @aio.BinaryReader] read_some(
  reader : R,
  max_len : Int32,
) -> Bytes? raise @aio.ReaderError {
  let buffer = FixedArray::make(max_len.min(65536), b'\x00')
  let count = reader.read_into(buffer.mut_view())
  if count == 0 {
    return None
  }
  let bytes = buffer.unsafe_reinterpret_as_bytes()
  Some(if count == bytes.length() { bytes } else { bytes[:count].to_owned() })
}
