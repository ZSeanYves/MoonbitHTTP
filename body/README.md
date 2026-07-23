# MoonbitHTTP/body

An async body-frame abstraction with `Data`, `Trailers`, `SizeHint`, empty/full
implementations, queued frames, bounded collection, and `BodyStream`.
`BodyStream` uses a bounded asynchronous queue (capacity 8 by default), so
protocol producers suspend instead of accumulating unbounded request data.
Normal completion and terminal I/O/protocol errors remain distinguishable.
Transport clients may use `BodyStream::from_pull` when each consumer read must
advance an incremental decoder without a detached reader task.
