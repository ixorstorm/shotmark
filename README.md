# ShotMark — macOS / Linux 截图标注工具

开源镜像：https://github.com/ixorstorm/shotmark （MIT，v1.0；唯一真实源仍在工作区，`scripts/publish.sh` 一键发布）

> A native macOS screenshot + annotation tool in pure Swift/AppKit — global hotkey, arrows/rects/mosaic/text, **scrolling capture with live stitch preview**, copy-to-clipboard. Zero dependencies, builds with `swiftc` alone (no Xcode needed).

> **类型: 研究（工具类）** | 状态: active | 定位: 截图 + 标注一步完成，回车即进剪贴板
> 2026-10-08 建（用户明确要求立项）。Swift/AppKit 原生，`swiftc` 直编，零第三方依赖。
> 机型约束：arm64 macOS 14+。

一句话：按 **⌃⇧A** → 拖选区域 → 画圈/箭头/打码/写字 → **回车进剪贴板**，全程不落地任何文件。

## 能力对照（飞书截图 → ShotMark）

| 飞书 | ShotMark |
|---|---|
| 全局热键唤起 | ⌃⇧A（Carbon RegisterEventHotKey，**不需要辅助功能权限**） |
| 拖选 + 八手柄调整 + 移动选区 | ✅ 8 手柄 resize + 内部拖拽移动 + 空白处重选 |
| 尺寸标签（W × H） | ✅ 选区左上角实时显示 |
| 矩形 / 椭圆（画圈） | ✅ |
| 箭头 | ✅ 直线 + 三角头 |
| 画笔 | ✅ 圆头自由轨迹 |
| 文字 | ✅ 点击落点，回车确认，字号随线宽 |
| 马赛克 | ✅ 底图 1/9 降采样 + 最近邻放大 |
| 撤销 | ✅ 工具栏按钮 / ⌘Z |
| 标注移动/缩放 | ✅ 点标注出虚线框 + 四角手柄：拖内部移动、拖角缩放（文字按比例缩字号、箭头动端点、画笔整体缩放）；画完自动选中；Esc 先取消选中再退出 |
| 颜色 | ✅ 红/橙/黄/绿/蓝/白/黑，7 色板 |
| 线宽 | ✅ 3 档循环（工具栏预览线实时反映颜色+线宽） |
| 复制到剪贴板 | ✅ ✓ 按钮 / 回车 / ⌘C；**剪贴板同时写 PNG+TIFF**（PNG 优先——UTM/SPICE 虚拟机剪贴板同步、Win/Linux 端都认 `public.png`，只放 TIFF 的话虚拟机里粘贴没反应） |
| 保存 | ✅ 存 `~/Pictures/ShotMark/ShotMark-<时间戳>.png` 并在 Finder 中 Reveal |
| **文字识别（OCR）** | ✅ 工具栏「文本取景」按钮 / **⌘O**：Vision 离线识别选区文字（中英文）→ **结果面板（飞书同款）**：先弹「识别中…」，出结果可查看/编辑/改选，点「复制文本」才进剪贴板；**暗色截图状态保留**（截图不准可重新框选、再按 ⌘O 重识别，或照常回车复制图）；Esc/关闭收起面板 |
| 钉在屏幕上 | ✅ 浮动小窗（可关可缩） |
| **滚动截屏** | ✅ 选区后点「回卷轴」图标：边框悬停提示 → 滚轮滚动 → **实时拼接预览** → 空格/回车完成，复制进剪贴板（toast 上可自选「保存」）；Esc 取消；**双向滚动拼接（上滚越过起点自动前插顶部）+ 手滑去重不误拼** |
| 追踪丢失 | 滚动过快导致无法拼接时，长图**在断点处截断收尾**（已复制已捕获部分，不丢不重复），提示后从断点重新开始即可；慢滚回滚可自动续接 |
| 取消 | ✅ ✕ 按钮 / Esc |
| 序号标注、钉图二次编辑 | ✗ 未做（见 TODO） |

## 安装与使用

```bash
make            # 编译出 ShotMark.app（swiftc 直出，无 Xcode 工程，CLT 即可）
make selftest   # 渲染自检：写 $TMPDIR 下 export.png（导出图）+ view.png（完整界面图）
make install    # 拷到 ~/Applications/
open ~/Applications/ShotMark.app
```

首次使用需授予「屏幕录制」权限（系统设置 → 隐私与安全性 → 屏幕录制与系统录音）。

1. 首次按 ⌃⇧A 会触发**屏幕录制权限**弹窗：系统设置 → 隐私与安全性 → 屏幕录制与系统录音 → 勾选 ShotMark，重启 App 后再按热键。
2. 覆盖层出现后：拖选 → 点工具（圈/箭头/笔/字/码）→ 在选区内画 → ✓ 或回车复制。
3. 再按一次 ⌃⇧A 或 Esc 关闭覆盖层。
4. 菜单栏有取景器图标（截图 / 打开保存目录 / 退出）。

开机自启：系统设置 → 通用 → 登录项 → 添加 `~/Applications/ShotMark.app`。

## 覆盖层内快捷键

| 键 | 动作 |
|---|---|
| Esc | 取消 |
| 回车 / 空格 / ⌘C | 复制到剪贴板并关闭 |
| ⌘S | 保存 PNG 并关闭 |
| ⌘Z | 撤销上一条标注 |

---

## Linux（GTK3 / X11，首版）

Linux 版位于独立的 `linux/` 树，**没有改动 `Sources/` 的 Swift/AppKit 实现，也不声称与 macOS 全量等价**。本机实测基线为 Ubuntu 24.04 x86_64、单一 3840×2160 X11 屏幕、GTK scale factor 2；raw 截图像素与 GTK 逻辑坐标在边界显式换算。

### 依赖与安装

运行时使用：Python 3、GTK3/PyGObject、pycairo/PangoCairo、Pillow（必须带 XCB）、python-xlib、numpy。滚动自动模式另需 X 服务器的 XTEST 扩展。运行时不需要 PyQt/PySide/mss/pynput/cv2；`xclip`、`xdotool` 只用于诊断和自动化 smoke。

Ubuntu 对应包名（本文只记录依赖，安装动作由用户自行决定）：

```bash
sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-pango-1.0 \
  python3-pil python3-xlib python3-numpy
# 可选诊断工具：
sudo apt install xclip xdotool
python3 -c 'from PIL import features; print("Pillow XCB:", features.check("xcb"))'
```

在项目根目录运行：

```bash
make linux-run                 # 常驻：注册热键并持有 CLIPBOARD
# 等价：PYTHONPATH=linux python3 -m shotmark
PYTHONPATH=linux python3 -m shotmark capture  # 直接弹一次截图层（UI smoke/热键冲突诊断）
```

复制后不要退出常驻进程：GTK 是剪贴板 owner，覆盖层关闭不影响粘贴，但整个 ShotMark 进程退出后，没有剪贴板管理器接管时其他应用将读不到这张图。

### 热键与冲突回退

首选热键是 **Ctrl+Shift+A**，再按一次或 Esc 取消。Linux 使用独占 `XGrabKey`，不会像被动监听那样让两个全屏截图客户端同时响应。若首选组合已被占用，会依次尝试：

1. **Ctrl+Alt+Shift+A**（本机实测首选被占用，当前自动使用此项）
2. Ctrl+Shift+F8
3. Ctrl+Alt+S

启动日志、桌面通知、托盘 tooltip 和截图层提示均显示**实际生效热键**。可显式覆盖，不必改源码：

```bash
SHOTMARK_HOTKEY=ctrl+shift+f8 make linux-run
PYTHONPATH=linux python3 -m shotmark --hotkey ctrl+alt+s
```

### 已实现功能与快捷键

- 鼠标拖选、选区内部移动、8 手柄 resize、实时 `W × H`；raw 像素导出采用显式半开裁剪。
- pen / arrow / rect / ellipse / text / mosaic；红橙黄绿蓝白黑 7 色、细中粗 3 档线宽、撤销。
- 文字在选区内用 GTK Entry 实际编辑，Enter 提交文字，再按 Enter 复制。mosaic 从**已裁剪选区底图**缩块生成，不使用灰色占位。
- Enter / Space / Ctrl+C 复制 PNG；Ctrl+S 或「保存」写到 `~/Pictures/ShotMark/ShotMark-<时间戳>.png`；「钉图」是可关闭、可缩放的置顶预览窗。
- 「滚动」= 手动滚轮；「自动滚」= XTEST 在选区中心发送小步长 Button5。抓帧 → 匹配/拼接 → 发送下一次滚动为 single-flight，抓帧耗时计入下一拍间隔且不重入。XTEST 不可用或注入失败会在提示条明确回退手动。
- 拼接支持向下追加、向上前插、双向水位线去重、实时预览。最小重叠、双侧纹理、次优决断、搜索边界和三段一致性闸门不全就不猜；连续 3 次有效失配只截断并复制可信部分，不保留洞、不做启发式错拼。
- 自动模式在 `dy=0` 且零新增连续 12 拍后判定页尾完成；抓帧失败不算静止证据。手动模式不因暂停而自动完成。滚动时 Space/Enter 完成，Esc 取消且不改旧剪贴板。
- 自身边框严格在选区外；首帧隐藏全部自身窗口，后续对真实矩形与选区相交的 hint/预览执行 hide → `Gdk.flush` → XSync round-trip → 抓帧，避免 root 截图拼入 ShotMark 自身像素。

Linux 覆盖层快捷键：

| 键 | 动作 |
|---|---|
| 实际热键（首选 Ctrl+Shift+A） | 唤起；再按取消 |
| Esc | 取消截图/滚动；文字编辑时先关闭编辑器 |
| Enter / Space / Ctrl+C | 普通截图复制 PNG；滚动时 Space/Enter 完成 |
| Ctrl+S | 保存 PNG |
| Ctrl+Z | 撤销上一条标注 |

### 测试与诊断入口

```bash
make linux-selftest         # 纯离线 unittest；不需要 DISPLAY
make linux-capture-test     # 真实 X11：非空、多色、方差与精确尺寸断言
make linux-ui-smoke         # 不足 1s 合成底图 GTK 交互/六类标注/文本提交/钉图
make linux-scroll-test      # 受控真实窗口 + XTEST 自动滚动 + 自身污染/拼接像素闸门
make linux-clipboard-test   # 外部 xclip 校验 TARGETS 与 image/png 回读（会写入测试图）
# 直接 unittest：
PYTHONPATH=linux python3 -m unittest discover -s linux/tests -v
# 指定真实捕获区域：
PYTHONPATH=linux python3 -m shotmark capture-test --region 100,100,900,700
```

诊断产物写入被 gitignore 的 `linux/build/`。离线拼接测试逐字节精确断言；真实屏幕路径另允许 mutter/GPU 合成造成的小幅色彩波动（当前实测 max 11/255），但对错位、重复、蓝边框和暗色预览污染保持很窄的失败阈值。

### Linux 源码结构

```text
linux/
├── shotmark/
│   ├── __main__.py             # run/capture/capture-test/ui-smoke/scroll-test/clipboard-test
│   ├── app.py                  # 常驻编排、实际热键提示、复制/保存/钉图、剪贴板生命周期
│   ├── core/                   # 不 import GTK/X11
│   │   ├── geometry.py         # raw 像素 Rect、移动与 8 手柄 resize
│   │   ├── annotations.py      # 六工具模型、7 色、3 线宽、撤销文档
│   │   ├── render.py           # Pillow 半开裁剪、像素映射、文字与底图 mosaic
│   │   └── stitch.py           # 双向匹配闸门、水位线、去重、截断与无洞 compose
│   ├── platform/x11/
│   │   ├── capture.py          # Pillow XCB 截图与真实 capture smoke
│   │   ├── hotkey.py           # XGrabKey、锁键变体、自动 fallback、会话键
│   │   ├── wheel.py            # XTEST Button4/5 与指针恢复
│   │   └── clipboard.py        # GTK CLIPBOARD owner，提供 image/png
│   └── ui/
│       ├── shot.py             # 选区、工具栏、标注预览、inline 文本与快捷键
│       ├── scroll.py           # 边框/hint/预览与 single-flight 滚动驱动
│       ├── widgets.py          # 钉图与 toast
│       └── scroll_smoke.py     # 受控端到端滚动诊断（非生产截图路径）
└── tests/                      # core 离线像素/场景单元测试
```

### Linux 已知限制（不宣称 macOS 全量 parity）

- **只支持 X11。未实现原生 Wayland，也不把 Xwayland 伪装成完整 Wayland 桌面支持。** 首版按单一 X screen/当前主显示器设计，不宣称多显示器一致性。
- OCR 未实现；序号标注未实现；钉图不能二次编辑；已提交标注暂不支持点选移动/缩放（可 Ctrl+Z 重画）。
- 滚动结果直接复制，不回到标注层。手动快甩超出重叠量程会在 3 次失败后截断，本首版不做失速重锚；慢速滚动、回滚和自动小步长是可靠路径。
- 不自动识别/去除吸顶栏（macOS 该实验也已回滚）：请把选区框在内容区、避开吸顶栏；低纹理/大片纯空白区会拒绝匹配，连续失败则截断而不是猜测拼接。
- 贴图仅预览，无 macOS Finder Reveal；保存通知不自动打开文件管理器。托盘图标依赖桌面 shell 是否支持 legacy status icon，热键是主要入口。

---

## 架构

```
Sources/
├── main.swift        # NSApplication accessory 启动
├── AppDelegate.swift # 状态栏图标、截图编排、完成动作（复制/保存/钉图）、权限弹窗
├── HotKey.swift      # Carbon RegisterEventHotKey（⌃⇧A，顶层 C 回调 → 主线程）
├── Capture.swift     # ScreenCaptureKit SCScreenshotManager 按屏/按区域捕获（Retina 像素）
├── ScrollCapture.swift # 滚动截屏会话：定时抓帧 + 帧间模板匹配求位移 + 逐帧拼接 + 边框提示窗
├── ShotView.swift    # 核心交互视图：选区/手柄/拖拽/标注预览/工具栏/文字编辑/快捷键
├── Model.swift       # Tool / Annotation / 调色板
├── Render.swift      # 标注绘制（视图与导出共用）、马赛克、导出裁剪、PNG 编码、图标着色
└── SelfTest.swift    # --selftest：假底图 + 六类标注 → 两张 PNG
```

关键实现点：

- **视图与导出共用一套标注绘制代码**（`Render.draw`）：导出时给 context 套 `translate(-sel.origin) → scale(×2)` 仿射，Retina 下导出的就是 2x 像素图。
- **马赛克**：把选区对应底图块画进 1/9 大小的临时 rep，再 `imageInterpolation = .none` 放大回来。
- **滚动截屏拼接**（v5，模糊匹配 + 幻影五闸门 + 速度自适应抓帧）：`SCStreamConfiguration.sourceRect` 只抓选区（150ms/拍），`SCContentFilter(excludingWindows:)` + 窗口 `sharingType=.none` 双保险让边框/预览窗**对截屏隐身**。匹配器 = 逐 dy 扫重叠区平均像素差（粗扫步长 8 + 精扫 ±1），**五道幻影闸门全部由真实事故反推**：① 纹理闸门（候选先按重叠区高对比像素双侧取小 ≥48 过滤，防全白 err=0 假对齐与单侧字形出血）② 边界否决（贴 maxDelta 的候选必须 err<1.5，防 dy=660 顶边界擦边幻影）③ 恒要求 fineErr < 0.6×secondErr 显著优于次优（防渐变/平坦地形假匹配，无「近乎全等」豁免）④ fineErr < 5.0 阈值 ⑤ 最小重叠 25%（防小重叠白色口袋幻影）。**双向竞争按重叠行数**（噪声帧上反向幻影 err 更低是常态，err 竞争会被噪声带偏）。**失速重锚定**：快滚甩出帧间量程后，把当前帧到 1/4 降采样长图上滑窗粗搜 + 全分辨率五闸门验证——用户回滚到已拼过的任何位置即自动续接（提示条会告知「回滚到已拼过的画面即可自动续接」）。**水位线双向去重**：下滚后插、上滚前插、已覆盖区不重复。调研参照：[ShareX ScrollingCaptureManager 源码](https://raw.githubusercontent.com/ShareX/ShareX/master/ShareX.ScreenCaptureLib/ScrollingCaptureManager.cs)、[Android 长截图 tile 匹配](https://gitlab.e.foundation/e/os/android_frameworks_base/-/commit/be15324c5d5be2130d9dbad583848d7fa50223bc)、[OpenCV 运动分析文档](https://docs.opencv.org/4.13.0/d7/df3/group__imgproc__motion.html)。**实时预览**：0.8s 节流浮动窗随拼接长大。拼接用 `NSImage.draw`（AppKit y-up 语义）——**不要用 `CGContext.draw(cgImage)`，bitmap context 里方向语义不可靠**。匹配器弯路存档：v3 模糊（幻影）→ v4 近似精确（SCK 分数像素重采样致恒 nil）→ v5 模糊+五闸门（平衡点，测试用例库兜底）。
- **会话期临时热键**：滚动截屏时用 Carbon 注册无修饰键的空格/回车/Esc（id 空间与 ⇧⌘A 分开），会话结束即注销，全程不需要辅助功能权限。
- **全局热键用 Carbon 而非 pynput/CGEventTap**：`RegisterEventHotKey` 不需要辅助功能权限，进程后台挂着也能收。
- **多屏**：**目标屏 = 鼠标所在屏**（`NSEvent.mouseLocation` + `NSMouseInRect`，[口径来源](https://stackoverflow.com/questions/49624486/49624487)，飞书/CleanShot 同款），单屏单抓单覆盖层。⚠️ 不要多屏并行抓：SCK 并发 captureImage 会把两块屏的结果交换（实测事故）；屏→displayID 映射在主线程解析，displayID 失配按分辨率几何兜底。

## 图标

`make icon` 由 `scripts/gen-icon.swift` 矢量直绘 13 张 PNG（深蓝渐变圆角底 + 白色取景框四角 + 手绘红圈，逐尺寸单独渲染保证 16px 清晰）→ `iconutil` 出 `AppIcon.icns` → 打进 `Contents/Resources/` 并随签名封装。改设计改 `gen-icon.swift` 里 `drawIcon()` 即可。

## 屏幕录制权限排障（2026-10-08 实测踩过的坑，按序排查）

1. **「截图失败」弹窗但设置里开关是开的** → 那是**旧签名身份的僵尸授权**。TCC 按签名身份记账：ad-hoc 签名每次重编 cdhash 都变、授权即失效；且设置页还继续显示旧开关，极具迷惑性。
   - 根治：本仓库已用自签名证书「ShotMark Local Signing」（`scripts/make-signing-cert.sh`，跑一次即可），TCC 按 `identifier + 签名身份` 记忆，**重编不失效**。
   - 清僵尸记录：`tccutil reset ScreenCapture dev.shotmark`（注意服务名是 `ScreenCapture`，`ScreenCaptureKit` 不是合法服务名）。
2. **刚在弹窗里点了允许，还是失败**（`SCStreamErrorDomain -3801`）→ 授权**对正在运行的进程不生效**，必须完全退出再打开（菜单栏取景器图标 → 退出 ShotMark → 重新打开）。App 现在能识别 -3801 并直接提示这个操作。
3. **进程路径变了**（如从 `dev/` 旧目录跑的残留进程）→ 授权跟着旧路径/旧 cdhash 走了。先 `pgrep -fl ShotMark` 确认跑的是 `~/Applications/` 里的这份。

排查工具：`open ~/Applications/ShotMark.app --args --capture-test`（以真实 App 身份跑一次捕获，结果写 `$TMPDIR/shotmark-capture-test.log`，含 preflight 状态与真实错误码）。

## 性能

- **启动预热**：App 启动即后台拉 `SCShareableContent`（SCK/TCC 管线预热），第一次按热键就命中缓存。
- **内容清单缓存**：`SCShareableContent` 单拉 ~55ms，缓存 5s + 并发共享同一拉取任务——热键路径不再重复拉清单，滚动会话每拍省 ~55ms。
- **多屏并行抓图**：两屏 `withTaskGroup` 并行（串行 ~210ms → 并行 ≈ 单屏耗时）。
- 热键 → 覆盖层实测：预热后 ≈ 100-150ms。

## 踩坑实录

开发中遇到的 23 个 macOS 坑（TCC 僵尸授权、SCK 并发换屏、NSAffineTransform 组合语义、滚动拼接幻影匹配等），每条带现象/根因/修法/教训：[PITFALLS.md](PITFALLS.md)

## 已知限制 / TODO

- 无序号标注、钉图不可二次编辑、文字提交后不可改字（可移动/缩放，改字=⌘Z 重打）。
- 滚动截屏：双向拼接（上滚前插 / 下滚后插，水位线去重）；大面积纯白/低纹理区域滚动时会暂停追加、滚到有纹理处自动恢复（纹理闸门宁可不拼也不拼错）；长图完成后直接复制+保存，暂不支持回覆盖层再标注。
- 每帧匹配详情写 `$TMPDIR/shotmark-scroll.log`（dy/err/纹理分/追加量/水位线），拼接异常时把这份日志给我即可定位。
- 重新编译后 ad-hoc 签名变化可能使屏幕录制授权失效，重跑一次授权流程即可（自签名证书版不受影响，见下节）。
- 改热键：改 `Sources/HotKey.swift` 里的 `keyCode`/`modifiers` 两行后 `make`。

## 验证记录（2026-10-08）

- `make`：swiftc 6.3.2（CLT，无 Xcode 全量）一次通过。
- `make selftest`：export.png 六种标注全部正确渲染（椭圆/箭头/矩形/画笔/马赛克/文字），Retina 2x 输出；view.png 完整界面（蒙层/镂空/手柄/尺寸标签/工具栏选中态/色板/线宽预览/动作键）渲染正确。
- `open ShotMark.app`：进程存活、后台进程名单可见 `ShotMark`、`pkill` 后 0 残留。
- **真机截屏链路已实测通过**：`--capture-test` 以 App 真实身份双屏捕获 OK（3840×2160 + 3024×1964），用户热键实机确认可用（「好像好了」）。
- 权限链路排障记录见上节（僵尸授权 / -3801 重开生效 / 自签名证书根治）。

## 项目沿革

- 2026-10-08：应用户要求从 PyObjC 方案推翻重写为 Swift 原生；初版曾短暂落 `dev/shotmark/`（独立 git，2 commits），用户拍板「按正常项目保存」后迁入 `work/shotmark/`，随 workspace git 全机同步。原 dev/ 目录与 raynor 上的 bare 备份仓已清理（迁移后由 workspace 同步承担备份）。
