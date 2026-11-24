# Callback transport

Import `ZSeanYves/MoonbitHTTP/adapter/callback` to adapt a host's read, write and close callbacks to MoonBit's async binary I/O traits.

Use `@callback.CallbackTransport::new` with asynchronous read and write callbacks and an optional close callback. Each I/O callback receives a buffer, offset and length and returns the number of bytes transferred. A read count of zero signals EOF. A write must make progress. For an invalid count, the I/O error carries `CallbackCountError::InvalidReadCount` or `CallbackCountError::InvalidWriteCount`.
