# uv adapter

`CallbackTransport` bridges callback-based runtimes such as `uv.mbt` to
`moonbitlang/async/io.Reader` and `Writer`. The package deliberately does not pin
a particular uv release: pass the runtime's read, write, and close operations as
callbacks, then pass the adapter to `service` as its Reader and Writer.
