///|
pub(all) enum ClientProtocol {
  Http1
  Http2
  Http3
} derive(Eq, Debug, Compare, Hash)

///|
pub(all) struct ConnectionKey {
  scheme : String
  host : String
  port : Int
  proxy_endpoint : @transport.Endpoint?
  proxy_identity : String?
  tls_identity : String?
  protocol : ClientProtocol
  options_identity : String?
} derive(Eq, Debug, Compare, Hash)

///|
pub fn ConnectionKey::new(
  endpoint : @transport.Endpoint,
  proxy_identity : String?,
  tls_identity : String?,
  protocol : ClientProtocol,
  options_identity : String?,
  proxy_endpoint? : @transport.Endpoint? = None,
) -> ConnectionKey {
  {
    scheme: endpoint.scheme(),
    host: endpoint.host(),
    port: endpoint.port(),
    proxy_endpoint,
    proxy_identity,
    tls_identity,
    protocol,
    options_identity,
  }
}

///|
pub fn ConnectionKey::scheme(self : ConnectionKey) -> String {
  self.scheme
}

///|
pub fn ConnectionKey::host(self : ConnectionKey) -> String {
  self.host
}

///|
pub fn ConnectionKey::port(self : ConnectionKey) -> Int {
  self.port
}

///|
pub fn ConnectionKey::protocol(self : ConnectionKey) -> ClientProtocol {
  self.protocol
}

///|
pub fn ConnectionKey::proxy_endpoint(
  self : ConnectionKey,
) -> @transport.Endpoint? {
  self.proxy_endpoint
}

///|
pub(all) enum PoolError {
  InvalidLimits
  AtCapacity
  UnknownLease
  LeaseAlreadyReleased
  LeaseInUse
  IdExhausted
} derive(Eq, Debug)

///|
pub(all) struct PoolLimits {
  max_total : Int
  max_idle : Int
} derive(Eq, Debug)

///|
pub fn PoolLimits::defaults() -> PoolLimits {
  { max_total: 128, max_idle: 64, }
}

///|
pub fn PoolLimits::validate(self : PoolLimits) -> Result[Unit, PoolError] {
  if self.max_total < 1 || self.max_idle < 0 || self.max_idle > self.max_total {
    Err(InvalidLimits)
  } else {
    Ok(())
  }
}

///|
pub(all) enum PoolAcquire {
  Reused(Int)
  Created(Int)
} derive(Eq, Debug)

///|
pub(all) struct PoolLease {
  key : ConnectionKey
  id : Int
  mut released : Bool
} derive(Eq, Debug)

///|
pub fn PoolLease::id(self : PoolLease) -> Int {
  self.id
}

///|
pub fn PoolLease::key(self : PoolLease) -> ConnectionKey {
  self.key
}

///|
/// Whether this lease has already been returned to the pool.
pub fn PoolLease::is_released(self : PoolLease) -> Bool {
  self.released
}

///|
struct PoolEntry {
  key : ConnectionKey
  id : Int
  mut in_use : Bool
  mut reusable : Bool
  mut last_used : Int64
}

///|
pub struct ConnectionPool {
  limits : PoolLimits
  entries : Array[PoolEntry]
  evicted : Array[Int]
  mut next_id : Int
  mut clock : Int64
}

///|
pub fn ConnectionPool::new(
  limits? : PoolLimits = PoolLimits::defaults(),
) -> Result[ConnectionPool, PoolError] {
  match limits.validate() {
    Ok(_) => Ok({ limits, entries: [], evicted: [], next_id: 0, clock: 0L, })
    Err(error) => Err(error)
  }
}

///|
pub fn ConnectionPool::len(self : ConnectionPool) -> Int {
  self.entries.length()
}

///|
pub fn ConnectionPool::idle_len(self : ConnectionPool) -> Int {
  let mut count = 0
  for entry in self.entries {
    if !entry.in_use && entry.reusable {
      count += 1
    }
  }
  count
}

///|
/// Number of connection IDs waiting for the resource-owning caller to close.
pub fn ConnectionPool::evicted_len(self : ConnectionPool) -> Int {
  self.evicted.length()
}

///|
fn ConnectionPool::eviction_queue_full(self : ConnectionPool) -> Bool {
  self.evicted.length() >= self.limits.max_total
}

///|
fn ConnectionPool::tick(self : ConnectionPool) -> Int64 {
  let value = self.clock
  self.clock += 1L
  value
}

///|
fn ConnectionPool::evict_idle(self : ConnectionPool) -> Unit {
  while self.entries.length() > self.limits.max_total {
    if self.eviction_queue_full() {
      return
    }
    let mut selected = -1
    for index, entry in self.entries {
      if !entry.in_use &&
        entry.reusable &&
        (selected < 0 || entry.last_used < self.entries[selected].last_used) {
        selected = index
      }
    }
    if selected < 0 {
      break
    }
    let removed = self.entries.remove(selected)
    self.evicted.push(removed.id)
  }
  while self.idle_len() > self.limits.max_idle {
    if self.eviction_queue_full() {
      return
    }
    let mut selected = -1
    for index, entry in self.entries {
      if !entry.in_use &&
        entry.reusable &&
        (selected < 0 || entry.last_used < self.entries[selected].last_used) {
        selected = index
      }
    }
    if selected < 0 {
      break
    }
    let removed = self.entries.remove(selected)
    self.evicted.push(removed.id)
  }
}

///|
/// Removes one least-recently-used idle connection to make room for a new
/// key. Active leases are never selected.
fn ConnectionPool::evict_one_idle(self : ConnectionPool) -> Bool {
  if self.eviction_queue_full() {
    return false
  }
  let mut selected = -1
  for index, entry in self.entries {
    if !entry.in_use &&
      entry.reusable &&
      (selected < 0 || entry.last_used < self.entries[selected].last_used) {
      selected = index
    }
  }
  if selected < 0 {
    false
  } else {
    let removed = self.entries.remove(selected)
    self.evicted.push(removed.id)
    true
  }
}

///|
/// Returns IDs removed by automatic capacity, idle, or invalidation policy.
/// Resource-owning callers must close and forget the corresponding sessions.
pub fn ConnectionPool::take_evicted_ids(self : ConnectionPool) -> Array[Int] {
  let output = self.evicted.copy()
  self.evicted.clear()
  output
}

///|
pub fn ConnectionPool::acquire(
  self : ConnectionPool,
  key : ConnectionKey,
) -> Result[PoolAcquire, PoolError] {
  for entry in self.entries {
    if !entry.in_use && entry.reusable && entry.key == key {
      entry.in_use = true
      entry.last_used = self.tick()
      return Ok(Reused(entry.id))
    }
  }
  let mut total = 0
  for entry in self.entries {
    if entry.in_use || entry.reusable {
      total += 1
    }
  }
  if total >= self.limits.max_total {
    if !self.evict_one_idle() {
      return Err(AtCapacity)
    }
  }
  if self.next_id >= 0x7fffffff {
    return Err(IdExhausted)
  }
  let id = self.next_id
  self.next_id += 1
  self.entries.push({
    key,
    id,
    in_use: true,
    reusable: true,
    last_used: self.tick(),
  })
  Ok(Created(id))
}

///|
/// Acquires a lease object that carries its key and rejects double release.
pub fn ConnectionPool::acquire_lease(
  self : ConnectionPool,
  key : ConnectionKey,
) -> Result[PoolLease, PoolError] {
  let acquired = match self.acquire(key) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let id = match acquired {
    Reused(value) | Created(value) => value
  }
  Ok({ key, id, released: false, })
}

///|
pub fn ConnectionPool::release(
  self : ConnectionPool,
  id : Int,
  reusable : Bool,
) -> Result[Unit, PoolError] {
  for entry in self.entries {
    if entry.id == id {
      if !entry.in_use {
        return Err(LeaseAlreadyReleased)
      }
      if !reusable && self.eviction_queue_full() {
        return Err(AtCapacity)
      }
      entry.in_use = false
      entry.reusable = reusable
      entry.last_used = self.tick()
      if !reusable {
        for index, candidate in self.entries {
          if candidate.id == id {
            let removed = self.entries.remove(index)
            self.evicted.push(removed.id)
            break
          }
        }
      }
      self.evict_idle()
      return Ok(())
    }
  }
  Err(UnknownLease)
}

///|
/// Releases a lease once and verifies that it still belongs to this pool.
pub fn ConnectionPool::release_lease(
  self : ConnectionPool,
  lease : PoolLease,
  reusable : Bool,
) -> Result[Unit, PoolError] {
  if lease.released {
    return Err(LeaseAlreadyReleased)
  }
  let mut found = false
  for entry in self.entries {
    if entry.id == lease.id {
      found = true
      if entry.key != lease.key {
        return Err(UnknownLease)
      }
      break
    }
  }
  if !found {
    return Err(UnknownLease)
  }
  let result = self.release(lease.id, reusable)
  match result {
    Ok(_) => {
      lease.released = true
      Ok(())
    }
    Err(error) => Err(error)
  }
}

///|
pub fn ConnectionPool::remove(
  self : ConnectionPool,
  id : Int,
) -> Result[Unit, PoolError] {
  for index, entry in self.entries {
    if entry.id == id {
      if entry.in_use {
        return Err(LeaseInUse)
      }
      self.entries.remove(index) |> ignore
      return Ok(())
    }
  }
  Err(UnknownLease)
}

///|
/// Closes every idle entry for a key; active leases remain owned by callers.
pub fn ConnectionPool::close_idle(
  self : ConnectionPool,
  key : ConnectionKey,
) -> Unit {
  self.invalidate_key(key)
}

///|
pub fn ConnectionPool::invalidate_key(
  self : ConnectionPool,
  key : ConnectionKey,
) -> Unit {
  let mut index = self.entries.length() - 1
  while index >= 0 {
    if self.eviction_queue_full() {
      break
    }
    if self.entries[index].key == key && !self.entries[index].in_use {
      let removed = self.entries.remove(index)
      self.evicted.push(removed.id)
    }
    index -= 1
  }
}
