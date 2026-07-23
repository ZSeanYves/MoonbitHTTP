///|
pub async fn[R : @aio.Reader] read_into_buffer(
  reader : R,
  buffer : @codec.Buffer,
  read_size? : Int = 8192,
) -> Bool {
  match reader.read_some(max_len=read_size) {
    None => false
    Some(bytes) =>
      match buffer.feed(bytes) {
        Ok(_) => true
        Err(error) => raise error
      }
  }
}

///|
pub async fn[W : @aio.Writer] write_bytes(writer : W, bytes : Bytes) -> Unit {
  writer.write(bytes)
}
