///|
priv struct H3PendingWrite {
  bytes : Bytes
  fin : Bool
  mut offset : Int
}

///|
priv struct H3WriteQueue {
  streams : Map[Int64, @deque.Deque[H3PendingWrite]]
  mut order : Array[Int64]
  max_bytes : Int
  max_writes : Int
  mut bytes : Int
  mut count : Int
}

///|
fn H3WriteQueue::new(max_bytes : Int, max_writes : Int) -> H3WriteQueue {
  { streams: Map([]), order: [], max_bytes, max_writes, bytes: 0, count: 0, }
}

///|
fn H3WriteQueue::admit(
  self : H3WriteQueue,
  size : Int,
) -> Unit raise Http3Error {
  if size > self.max_bytes {
    raise Http3LimitExceeded(
      "HTTP/3 write exceeds queue capacity",
      self.max_bytes,
    )
  }
  if size > self.max_bytes - self.bytes || self.count >= self.max_writes {
    raise Http3WriteBlocked
  }
}

///|
fn H3WriteQueue::push(
  self : H3WriteQueue,
  id : Int64,
  bytes : Bytes,
  fin : Bool,
) -> Unit {
  let q = self.streams.get_or_init(id, fn() {
    self.order.push(id)
    @deque.from_array([])
  })
  q.push_back({ bytes, offset: 0, fin, })
  self.bytes += bytes.length()
  self.count += 1
}

///|
fn H3WriteQueue::drop(self : H3WriteQueue, id : Int64) -> Unit {
  guard self.streams.get(id) is Some(q) else { return }
  while q.pop_front() is Some(write) {
    self.bytes -= write.bytes.length()
    self.count -= 1
  }
  self.streams.remove(id)
  self.order = self.order.filter(active => active != id)
}

///|
fn H3WriteQueue::flush(
  self : H3WriteQueue,
  quic : @quic.QuicDatagramDriver,
  output : Array[Http3SessionAction],
  now_ms : Int64,
) -> Unit raise @quic.QuicError {
  let waiting = []
  let sent = []
  for id in self.order {
    guard self.streams.get(id) is Some(q) && q.front() is Some(write) else {
      continue
    }
    match
      quic.send_stream_prefix(id, write.bytes[write.offset:], write.fin, now_ms) {
      Ok(None) => waiting.push(id)
      Ok(Some((count, packet))) => {
        output.push(Transport(packet))
        write.offset += count
        if write.offset == write.bytes.length() {
          ignore(q.pop_front())
          self.count -= 1
          // Partial writes still retain the original allocation.
          self.bytes -= write.bytes.length()
        }
        if q.is_empty() {
          self.streams.remove(id)
        } else {
          sent.push(id)
        }
      }
      Err(StreamClosed(_)) => self.drop(id)
      Err(error) => raise error
    }
  }
  // Streams that saw no credit get first chance on the next tick.
  waiting.append(sent)
  self.order = waiting
}
