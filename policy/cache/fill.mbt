///|
/// Tracks an in-flight representation so invalidation also covers unfinished responses.
pub struct CacheFill {
  priv cache : HttpCache
  priv key : String
  priv request : @types.Request[Unit]
  priv mut chunks : Array[Bytes]?
  priv mut size : Int32
}

///|
pub fn HttpCache::begin_fill(
  self : HttpCache,
  request : @types.Request[Unit],
) -> CacheFill? {
  guard request.http_method == Get &&
    self.pending.length() < self.config.limits.max_entries &&
    cache_base_key(request) is Ok(key) else {
    return None
  }
  let fill : CacheFill = {
    cache: self,
    key,
    request: { ..request, headers: request.headers.copy(), },
    chunks: Some([]),
    size: 0,
  }
  self.pending.push(fill)
  Some(fill)
}

///|
fn HttpCache::discard_pending(self : HttpCache, key : String) -> Unit {
  for fill in self.pending.copy() {
    if fill.key == key {
      fill.discard()
    }
  }
}

///|
pub fn CacheFill::discard(self : CacheFill) -> Unit {
  guard self.chunks is Some(_) else { return }
  self.chunks = None
  self.cache.pending_bytes -= self.size
  for i, fill in self.cache.pending {
    if physical_equal(fill, self) {
      ignore(self.cache.pending.remove(i))
      break
    }
  }
}

///|
pub fn CacheFill::append(self : CacheFill, chunk : Bytes) -> Unit {
  guard self.chunks is Some(chunks) else { return }
  let limits = self.cache.config.limits
  if chunk.length() > limits.max_entry_bytes - self.size ||
    chunk.length() > limits.max_total_bytes - self.cache.pending_bytes {
    self.discard()
  } else if !chunk.is_empty() {
    chunks.push(chunk)
    self.size += chunk.length()
    self.cache.pending_bytes += chunk.length()
  }
}

///|
pub fn CacheFill::commit(
  self : CacheFill,
  response : @types.Response[Unit],
  trailers : @types.HeaderMap?,
  now : Int64,
) -> Unit {
  guard self.chunks is Some(chunks) else { return }
  defer self.discard()
  let data = @buffer.Buffer(capacity=self.size)
  for chunk in chunks {
    data.write_bytes(chunk)
  }
  ignore(
    self.cache.store(self.request, response, data.to_bytes(), now, trailers~),
  )
}
