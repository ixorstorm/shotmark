# ShotMark 踩坑实录（macOS 截图工具开发）

> 2026-10-08 ~ 10-12 三轮攻坚沉淀。每条都是真用户事故 → 日志/像素证据 → 根因 → 修法。
> 纪律：**不要猜，去查**；图像类检查必须有像素级断言兜底（人眼对整体平移不敏感）。

## 一、TCC 屏幕录制权限

### 1. 僵尸授权：ad-hoc 签名每次重编授权就失效
- **现象**：编译一次就要重新授权一次屏幕录制
- **根因**：TCC 授权跟着二进制的 cdhash 走，ad-hoc 签名每次重编 cdhash 都变
- **修法**：自签证书固定身份（`codesign --identifier dev.shotmark --timestamp=none`），授权跨重编保持有效
- **重置命令**：`tccutil reset ScreenCapture dev.shotmark`（⚠️ 服务名是 `ScreenCapture`，不是 `ScreenCaptureKit`）

### 2. -3801：授权存在但对当前进程未生效
- `SCStreamErrorDomain -3801` = TCC 记录里有授权，但**运行中的进程**还没继承到——必须退出重开 App，光重新授权不够

### 3. 锁屏下 SCK 只给壁纸
- macOS 隐私设计：锁屏界面盖住所有窗口，任何截图/录屏 API 只拿得到壁纸
- 修法：`CGSessionCopyCurrentDictionary` 的 `CGSSessionScreenIsLocked` 守卫，锁着就不弹覆盖层
- 注意：Carbon 全局热键**锁屏下照样能收到按键**，守卫必须自己加

## 二、窗口与内存

### 4. `isReleasedWhenClosed` 双重释放 crash（连崩 4 次才抓到）
- **现象**：空格完成截图后主线程 autorelease pool pop SIGSEGV
- **根因**：程序创建的 NSWindow 默认 `isReleasedWhenClosed = true`——`close()` 自释放，Swift 强属性随后 nil 化再释放一次 = double-free
- **修法**：一切程序创建的窗口一律 `isReleasedWhenClosed = false`
- **教训**：第一次误诊为 Carbon 热键回调里同步注销热键（也修了但不是它）——崩溃要看 .ips 原文，不要猜

### 5. 系统 tooltip 被覆盖层压住
- **现象**：按钮悬停不弹 tips
- **根因**：系统 tooltip 是独立小窗，层级比 shielding 级全屏覆盖层低
- **修法**：覆盖层内部自绘悬停药丸（0.55s 延迟浮出）

## 三、ScreenCaptureKit 捕获

### 6. SCK 并发抓多屏会交换结果（最阴的 bug）
- **现象**：外屏的覆盖层显示内屏的壁纸——「按热键就只剩背景」
- **根因**：两块屏并发 `captureImage`，日志里映射全对、各自配置全对，但返回的 CGImage 是**对调**的
- **修法**：目标屏 = 鼠标所在屏（`NSEvent.mouseLocation` + `NSMouseInRect`），单屏单抓单覆盖层，并行路径整个删掉
- **教训**：并发优化引入 heisenbug 的教科书案例

### 7. 跨线程读 `NSScreen.deviceDescription` 不可靠
- 屏→displayID 映射必须在**主线程**解析好再进后台任务

### 8. 显示器过渡期清单失配
- 合盖/休眠/插拔过渡期：`NSScreen` 报 2 屏、SCK 清单只剩 1 屏，displayID 匹配全灭
- 修法：displayID 失配按分辨率几何兜底 + 作废缓存拉新鲜清单

### 9. Tahoe 的 Launchpad 改名「应用程序」且 SCK 抓得到
- 曾因「抓到桌面没抓到启动台」误判为合成层不暴露——**翻案**：抓到了，白图是导出变换的锅（见 §四.10）
- 教训：先对比「捕获原图 vs 导出图」再下结论（证据落盘立功）

## 四、渲染与变换

### 10. `NSAffineTransform` 组合语义（白图真凶，藏了很多轮）
- **语义**：先 scale 后 translate（`p' = p*s + t`，实测 `translateX(10)+scale(2)` 后 (30,30) 落在 70 而非 80）
- **更糟**：在翻转位图上下文里组合行为完全不可控（网格扫描实锤：多数选区导出全透明）
- **隐蔽性**：内容+标注一起平移，相对位置全对，肉眼极难发现——「导出看着没问题」的检查全被骗过
- **彻底修法**：`Render.export` 弃用一切上下文变换——`CGImage.cropping` 按像素直裁底图 + 标注 `pixelMapped` 手动平移缩放后 1:1 绘制（文字只缩 `scale` 字段保字号等比）
- **教训**：凡图像正确性必须有像素级断言（区域四角锚点、文字差异像素框），禁止「看着对」

### 11. `NSImage.draw` vs `CGContext.draw(cgImage:)`
- bitmap 上下文里 `NSImage.draw(in:)` 可靠；`CGContext.draw(cgImage)` 方向语义不可靠——导出/落盘一律走 NSImage.draw

### 12. 文字基线对齐要逐像素实测，公式推不准
- `draw(at:)` 墨迹下沿 = `p.y + 4`（实测，不是文档里的 baseline 语义）
- NSTextField 框墨迹下沿 = `fieldY + fontSize*0.45`（实测）
- 反解 `fieldY = p.y - fontSize*0.25`，残差再校（水平 -2、垂直 -0.5）到 ≤1px
- 教训：字体光栅化的亚像素差异没法推，只能量

### 13. macOS 26 对角线缩放光标是私有 selector
- `_windowResizeNorthEastSouthWestCursor` / `_windowResizeNorthWestSouthEastCursor`，`NSCursor.perform` 取
- ⚠️ 上 App Store 的话这俩要换成自绘或公开 API（私有 API 审核风险）

## 五、滚动拼接

### 14. 宁可跳过也不拼错（幻影匹配五闸门）
- 模糊匹配会在「相似但错误」的偏移上幻影命中（dy=660 拼接错位事故）
- 五闸门：纹理量下限（双侧 min ≥48）、边界否决（贴近量程边缘要求误差 <1.5）、决断度（`fineErr < 0.6*secondErr`）、误差上限（<5.0）、最小重叠 25%
- 跳过的帧靠重锚定自愈，永远别猜

### 15. 失速自救（重锚定）
- 快滚一甩位移超出帧间量程（maxDelta=帧高-60）→ 永久失速（日志实锤 15+ 拍 err 恒定 = 卡死）
- 修法：主匹配失败时把当前帧到 1/4 降采样长图滑窗粗搜 + 全分辨率五闸门验证，认出「你回滚到这了」接着拼

### 16. 抓帧率自适应
- 150ms 固定拍跟不上惯性快滚 → 滚速超阈值切 70ms 快拍

## 六、工程基建

### 17. 定时器守卫吃掉初始定时器（「滚动又不拼接了」）
- `scheduleTimer(0.15)` 有「没变不重建」守卫，而 `tickInterval` 初值恰好也是 0.15 → 初始定时器从未创建，滚动会话只有第一帧
- 自检全绕过定时器直驱 `process()` → 全绿但真机不跑
- 修法：初值归 0 + 补 `--selftest-live` 真机冒烟（真定时器+真 SCK+真会话）
- **教训：守卫/缓存/初始值三件套叠加时，初值不能等于首个合法调度值**

### 18. 剪贴板只写 TIFF，虚拟机里粘贴没反应
- `writeObjects([NSImage])` 只给 TIFF；UTM/SPICE 剪贴板同步、Win/Linux 端都认 `public.png`
- 修法：显式 `setData(png, forType: .png)` + TIFF 兜底

### 19. 空心形状命中测试只命中描边沿线
- 否则「画个圈再在里面写字」会把圈选中而不是开文本框（圈内打字根本没创建事故）

### 20. 热键路径性能三件套
- 预热（启动即后台拉 SCK 管线）+ 5s 清单缓存（失配才回退新鲜拉取）+ 常驻保温定时器（每 4s 刷）
- 曾经手滑把热键路径改成每次新鲜拉取（70-110ms），预热白做——热键只抓一屏，清单必须走缓存

### 21. Carbon `RegisterEventHotKey` 全局热键不需要辅助功能权限
- 比 `CGEventTap` 路线省心得多（那个要辅助功能授权）

### 22. `open` 启动的 App 看不到 stderr
- 调试日志写文件（`$TMPDIR/shotmark-*.log`），别指望 stdout/stderr
- 排障基建：`--capture-test`（抓图落 PNG，终端/App 两身份对比）、`--overlay-test`（完整热键路径回放）、`--toast-test`、`--selftest --selftest-live`

## 七、开源发布

### 23. ghfast.top 镜像改写撞凭证墙
- 全局 gitconfig 有 `url.https://ghfast.top/https://github.com/.insteadof` → 推 GitHub 时凭证助手匹配不到 ghfast.top → 挂起
- 修法：`GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 git push`（osxkeychain 在系统级配置不受影响）
- 镜像发布：`git subtree split --prefix=work/shotmark` 保留真实历史（见 `scripts/publish.sh`）
