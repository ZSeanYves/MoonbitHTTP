///|
/// Disjoint unacknowledged intervals, ordered by offset. Sequential writes
/// extend the last interval without allocating a record per packet.
priv struct SentStreamRanges {
  ranges : Array[(Int64, Int64)]
  mut bytes : Int64
}

///|
fn SentStreamRanges::append(
  self : SentStreamRanges,
  offset : Int64,
  length : Int64,
) -> Unit {
  if length == 0L {
    return
  }
  let end = offset + length
  match self.ranges.last() {
    Some((start, previous)) if previous == offset =>
      self.ranges[self.ranges.length() - 1] = (start, end)
    _ => self.ranges.push((offset, end))
  }
  self.bytes += length
}

///|
fn SentStreamRanges::release(
  self : SentStreamRanges,
  offset : Int64,
  end : Int64,
) -> Int64 {
  let ranges = self.ranges
  if end <= offset || ranges.is_empty() {
    return 0L
  }
  let first = match ranges.binary_search_by(range => range.1.compare(offset)) {
    Ok(index) => index + 1
    Err(index) => index
  }
  if first == ranges.length() || ranges[first].0 >= end {
    return 0L
  }
  let (left, right) = ranges[first]
  if left < offset && end < right {
    ranges[first] = (left, offset)
    ranges.insert(first + 1, (end, right))
    let released = end - offset
    self.bytes -= released
    return released
  }
  // Preserve at most two boundary fragments and move the untouched tail once.
  let mut read = first
  let mut write = first
  let mut released = 0L
  while read < ranges.length() && ranges[read].0 < end {
    let (left, right) = ranges[read]
    released += right.min(end) - left.max(offset)
    if left < offset {
      ranges[write] = (left, offset)
      write += 1
    }
    if right > end {
      ranges[write] = (end, right)
      write += 1
    }
    read += 1
  }
  if write < read {
    let tail = ranges.length() - read
    ranges[read:].blit_to(ranges, dst_offset=write)
    ranges.truncate(write + tail)
  }
  self.bytes -= released
  released
}
