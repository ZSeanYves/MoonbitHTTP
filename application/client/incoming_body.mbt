///|
/// A readable, cancellable body. Consuming trailers or EOF completes its ownership scope.
pub struct IncomingBody {
  priv mut reading : Bool
  priv hint : @body.SizeHint
  priv mut state : IncomingState
}

///|
priv enum IncomingState {
  Readable(IncomingReader, (Error) -> Unit, () -> Unit)
  Finished
  Failed(Error)
}

///|
priv enum IncomingReader {
  Single(async () -> @body.Frame?)
  Batch(async (Int32) -> Array[@body.Frame])
}

///|
fn IncomingBody::new(
  read : IncomingReader,
  hint : @body.SizeHint,
  stop : (Error) -> Unit,
  done~ : () -> Unit = () => (),
) -> IncomingBody {
  { hint, reading: false, state: Readable(read, stop, done), }
}

///|
fn IncomingBody::on_done(self : IncomingBody, release : () -> Unit) -> Unit {
  match self.state {
    Readable(read, stop, done) =>
      self.state = Readable(read, stop, () => {
        done()
        release()
      })
    Finished | Failed(_) => release()
  }
}

///|
pub fn[B : @body.Body] IncomingBody::wrap(body : B) -> IncomingBody {
  IncomingBody::new(Single(() => body.next_frame()), body.size_hint(), reason => {
    body.cancel(reason)
  })
}

///|
pub impl @body.Body for IncomingBody with fn size_hint(self) {
  self.hint
}

///|
pub impl @body.Body for IncomingBody with fn cancel(self, reason) {
  if self.state is Readable(_, stop, done) {
    self.state = Failed(reason)
    stop(reason)
    done()
  }
}

///|
async fn[X] IncomingBody::consume(
  self : IncomingBody,
  eof : X,
  run : async (IncomingReader) -> (X, Bool),
) -> X {
  let (reader, done) = match self.state {
    Failed(reason) => raise reason
    Finished => return eof
    Readable(reader, _, done) => (reader, done)
  }
  guard !self.reading else {
    raise ClientProtocol("concurrent reads of one response body")
  }
  self.reading = true
  defer {
    self.reading = false
  }
  errdefer self.cancel(@body.BodyError::Cancelled)
  let (value, ended) = run(reader) catch {
    reason => {
      let first = match self.state {
        Failed(saved) => saved
        _ => reason
      }
      self.cancel(first)
      raise first
    }
  }
  if self.state is Failed(reason) {
    raise reason
  }
  if ended {
    self.state = Finished
    done()
  }
  value
}

///|
pub impl @body.Body for IncomingBody with fn next_frame(self) {
  self.consume(None, async fn(reader) {
    let frame = match reader {
      Single(read) => read()
      Batch(read) => read(1).get(0)
    }
    (frame, frame is (None | Some(Trailers(_))))
  })
}

///|
/// Pull at most `max_frames` frames. May wait for that many frames, trailers,
/// or EOF. Trailers are included once. An empty batch means EOF. A positive
/// bound limits frame count, not byte count. Only one read may run at a time.
pub async fn IncomingBody::read_batch(
  self : IncomingBody,
  max_frames : Int32,
) -> Array[@body.Frame] {
  if max_frames < 1 {
    raise ClientInvalidOptions("max_frames must be positive")
  }
  self.consume([], async fn(reader) {
    let frames = match reader {
      Batch(read) => read(max_frames)
      Single(read) => {
        let frames = []
        for i in 0..<max_frames {
          if i > 0 && i % 64 == 0 {
            @async.pause()
          }
          if self.state is Failed(reason) {
            raise reason
          }
          guard read() is Some(frame) else { break }
          frames.push(frame)
          if frame is Trailers(_) {
            break
          }
        }
        frames
      }
    }
    (frames, frames.length() < max_frames || frames.last() is Some(Trailers(_)))
  })
}

///|
pub extend IncomingBody with @body.Body::{next_frame, size_hint, cancel}

///|
fn saved_body(data : Bytes, trailers : @types.HeaderMap?) -> IncomingBody {
  let frames : Array[@body.Frame] = []
  if !data.is_empty() {
    frames.push(Data(data))
  }
  if trailers is Some(fields) {
    frames.push(Trailers(fields))
  }
  IncomingBody::wrap(@body.QueueBody::new(frames))
}

///|
/// Each demand wakes one cancellable reader. A batch shares a single
/// rendezvous across the frames explicitly requested by the consumer.
fn Client::scoped_response(
  self : Client,
  source : IncomingBody,
  done : () -> Unit,
) -> IncomingBody {
  let demand = @cond_var.Cond()
  let ready = @cond_var.Cond()
  let mut reader : @async.Task[Unit]? = None
  let mut requested = 0
  let mut answer : Result[Array[@body.Frame], Error]? = None
  IncomingBody::new(
    Batch(async fn(count) {
      requested = count
      if reader is None {
        reader = Some(
          self.group.spawn(
            async fn() {
              while answer is None {
                let batch = Ok(source.read_batch(requested)) catch {
                  error => Err(error)
                }
                answer = Some(batch)
                ready.signal()
                guard batch is Ok(_) && source.state is Readable(_, _, _) else {
                  return
                }
                demand.wait()
              }
            },
            no_wait=true,
            allow_failure=true,
          ),
        )
      } else {
        demand.signal()
      }
      while answer is None {
        ready.wait()
      }
      let batch = answer.unwrap()
      answer = None
      batch.unwrap_or_error()
    }),
    source.size_hint(),
    error => {
      if reader is Some(task) {
        task.cancel()
      }
      answer = Some(Err(error))
      ready.signal()
      source.cancel(error)
    },
    done~,
  )
}
