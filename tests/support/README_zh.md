# `tests/support`

[English](README.md) · [项目说明](../../README_zh.md)

仓库测试共用的辅助包。流式测试可使用 `RecordingWriter` 并注入读写错误；数据报测试可使用内存套接字；时间相关测试使用 `FixedClock`。发布归档排除测试包。

`FixedClock::new` 的首个参数是单调时间（毫秒），第二个参数是 Unix 时间（秒）。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/tests/support",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "advance a test clock" {
  let clock = @support.FixedClock::new(100L, 0L)
  let before = clock.monotonic_millis()
  clock.advance(25L).unwrap()
  assert_eq(clock.monotonic_millis(), before + 25L)
}
```
