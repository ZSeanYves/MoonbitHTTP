# `runtime/detection`

[English](README.md) · [项目说明](../../README_zh.md)

通过协商得到的 ALPN 或分段到达的明文字节识别 HTTP/1、HTTP/2。`Detector` 保留传入 `feed` 的全部字节。得出结果后停止送入数据，将 `buffered()` 的完整内容交给对应驱动，其中可能含有前言之后的帧。`is_h2c_upgrade` 识别升级首部，升级设置由服务驱动校验。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/runtime/detection",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "detect a split HTTP/2 preface" {
  let detector = @detection.Detector::new()
  assert_true(detector.feed(b"PRI * HTTP/2.0\r\n") is Undetermined)
  assert_true(detector.feed(b"\r\nSM\r\n\r\n") is Detected(Http2PriorKnowledge))
  assert_eq(detector.buffered().length(), 24)
}
```
