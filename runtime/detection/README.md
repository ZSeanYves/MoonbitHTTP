# `runtime/detection`

[中文](README_zh.md) · [Project README](../../README.md)

Select HTTP/1 or HTTP/2 from negotiated ALPN or incremental cleartext input. `Detector` retains every byte supplied to `feed`. Once decided, stop feeding it and pass `buffered()` to the chosen protocol driver, including bytes received after the preface. `is_h2c_upgrade` recognizes upgrade headers. The service driver validates the upgrade settings.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/runtime/detection",
} for "test"
```

Save as `example_test.mbt`.

```moonbit
test "detect a split HTTP/2 preface" {
  let detector = @detection.Detector::new()
  assert_true(detector.feed(b"PRI * HTTP/2.0\r\n") is Undetermined)
  assert_true(detector.feed(b"\r\nSM\r\n\r\n") is Detected(Http2PriorKnowledge))
  assert_eq(detector.buffered().length(), 24)
}
```
