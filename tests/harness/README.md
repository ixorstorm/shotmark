# 滚动拼接跑分器（离线复刻场景评分）

高保真复刻成员列表页（暗色/等高卡片/低对比）+ 7 个滚动场景，逐带像素误差客观评分。
驱动 `Sources/ScrollCapture.swift` 的会话，无需屏幕捕获权限。

## 运行

```bash
xcrun swiftc -O -o /tmp/smtest/run \
  $(ls Sources/*.swift | grep -v "Sources/main.swift") \
  tests/harness/harness_main.swift \
  -framework AppKit -framework Carbon -framework ScreenCaptureKit -framework Vision \
  -swift-version 5 -sdk $(xcrun --sdk macosx --show-sdk-path) -target arm64-apple-macosx14.0
/tmp/smtest/run
```

## 场景

- A 慢滚 87/拍 · B 快甩 500 · C 到底回滚 · D 中途复看 · E 连甩 300 · H 到底静止自动完成
- F/G 停靠栏（XFAIL 已知限制：顶栏会重复，内容完整）

评分：composite 逐 20 行带 vs 源图（base = 首帧偏移），maxBandErr < 0.35 且高度覆盖 ± 才 PASS。
