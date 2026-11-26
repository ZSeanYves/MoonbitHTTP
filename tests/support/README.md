# `tests/support`

[中文](README_zh.md) · [Project README](../../README.md)

Test helpers used within this checkout. Exercise streaming code with `RecordingWriter` and injected read or write errors, datagram code with an in-memory socket, and time-dependent code with `FixedClock`. The module archive excludes test packages.

`FixedClock::new` takes the monotonic time in milliseconds and the wall time in Unix seconds, in that order.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/tests/support",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "advance a test clock" {
  let clock = @support.FixedClock::new(100L, 0L)
  let before = clock.monotonic_millis()
  clock.advance(25L).unwrap()
  assert_eq(clock.monotonic_millis(), before + 25L)
}
```
