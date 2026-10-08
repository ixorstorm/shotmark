# ShotMark — macOS 截图标注工具（对标飞书截图）

> **类型: 研究（工具类）** | 状态: active | 定位: 截图 + 标注一步完成，回车即进剪贴板
> 2026-10-08 建（用户明确要求立项）。Swift/AppKit 原生，`swiftc` 直编，零第三方依赖。
> 机型约束：arm64 macOS 14+（开发机 guns-roses，macOS 26.6.2 实测）。

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
| 颜色 | ✅ 红/橙/黄/绿/蓝/白/黑，7 色板 |
| 线宽 | ✅ 3 档循环（工具栏预览线实时反映颜色+线宽） |
| 复制到剪贴板 | ✅ ✓ 按钮 / 回车 / ⌘C |
| 保存 | ✅ 存 `~/Pictures/ShotMark/ShotMark-<时间戳>.png` 并在 Finder 中 Reveal |
| 钉在屏幕上 | ✅ 浮动小窗（可关可缩） |
| 取消 | ✅ ✕ 按钮 / Esc |
| 序号标注、钉图二次编辑 | ✗ 未做（见 TODO） |

## 安装与使用

```bash
cd work/shotmark
make            # 编译出 ShotMark.app（swiftc 直出，无 Xcode 工程，CLT 即可）
make selftest   # 渲染自检：写 /tmp 下 export.png（导出图）+ view.png（完整界面图）
make install    # 拷到 ~/Applications/
open ~/Applications/ShotMark.app
```

1. 首次按 ⌃⇧A 会触发**屏幕录制权限**弹窗：系统设置 → 隐私与安全性 → 屏幕录制与系统录音 → 勾选 ShotMark，重启 App 后再按热键。
2. 覆盖层出现后：拖选 → 点工具（圈/箭头/笔/字/码）→ 在选区内画 → ✓ 或回车复制。
3. 再按一次 ⌃⇧A 或 Esc 关闭覆盖层。
4. 菜单栏有取景器图标（截图 / 打开保存目录 / 退出）。

开机自启：系统设置 → 通用 → 登录项 → 添加 `~/Applications/ShotMark.app`。

## 覆盖层内快捷键

| 键 | 动作 |
|---|---|
| Esc | 取消 |
| 回车 / ⌘C | 复制到剪贴板并关闭 |
| ⌘S | 保存 PNG 并关闭 |
| ⌘Z | 撤销上一条标注 |

## 架构

```
Sources/
├── main.swift        # NSApplication accessory 启动
├── AppDelegate.swift # 状态栏图标、截图编排、完成动作（复制/保存/钉图）、权限弹窗
├── HotKey.swift      # Carbon RegisterEventHotKey（⌃⇧A，顶层 C 回调 → 主线程）
├── Capture.swift     # ScreenCaptureKit SCScreenshotManager 按屏捕获（Retina 像素）
├── ShotView.swift    # 核心交互视图：选区/手柄/拖拽/标注预览/工具栏/文字编辑/快捷键
├── Model.swift       # Tool / Annotation / 调色板
├── Render.swift      # 标注绘制（视图与导出共用）、马赛克、导出裁剪、PNG 编码、图标着色
└── SelfTest.swift    # --selftest：假底图 + 六类标注 → 两张 PNG
```

关键实现点：

- **视图与导出共用一套标注绘制代码**（`Render.draw`）：导出时给 context 套 `translate(-sel.origin) → scale(×2)` 仿射，Retina 下导出的就是 2x 像素图。
- **马赛克**：把选区对应底图块画进 1/9 大小的临时 rep，再 `imageInterpolation = .none` 放大回来。
- **全局热键用 Carbon 而非 pynput/CGEventTap**：`RegisterEventHotKey` 不需要辅助功能权限，进程后台挂着也能收。
- **多屏**：每屏一个 borderless 窗口（`CGShieldingWindowLevel` + `canJoinAllSpaces`），各自捕获各自标注，任一屏完成动作即全部关闭。

## 图标

`make icon` 由 `scripts/gen-icon.swift` 矢量直绘 13 张 PNG（深蓝渐变圆角底 + 白色取景框四角 + 手绘红圈，逐尺寸单独渲染保证 16px 清晰）→ `iconutil` 出 `AppIcon.icns` → 打进 `Contents/Resources/` 并随签名封装。改设计改 `gen-icon.swift` 里 `drawIcon()` 即可。

## 屏幕录制权限排障（2026-10-08 实测踩过的坑，按序排查）

1. **「截图失败」弹窗但设置里开关是开的** → 那是**旧签名身份的僵尸授权**。TCC 按签名身份记账：ad-hoc 签名每次重编 cdhash 都变、授权即失效；且设置页还继续显示旧开关，极具迷惑性。
   - 根治：本仓库已用自签名证书「ShotMark Local Signing」（`scripts/make-signing-cert.sh`，跑一次即可），TCC 按 `identifier + 签名身份` 记忆，**重编不失效**。
   - 清僵尸记录：`tccutil reset ScreenCapture dev.shotmark`（注意服务名是 `ScreenCapture`，`ScreenCaptureKit` 不是合法服务名）。
2. **刚在弹窗里点了允许，还是失败**（`SCStreamErrorDomain -3801`）→ 授权**对正在运行的进程不生效**，必须完全退出再打开（菜单栏取景器图标 → 退出 ShotMark → 重新打开）。App 现在能识别 -3801 并直接提示这个操作。
3. **进程路径变了**（如从 `dev/` 旧目录跑的残留进程）→ 授权跟着旧路径/旧 cdhash 走了。先 `pgrep -fl ShotMark` 确认跑的是 `~/Applications/` 里的这份。

排查工具：`open ~/Applications/ShotMark.app --args --capture-test`（以真实 App 身份跑一次捕获，结果写 `$TMPDIR/shotmark-capture-test.log`，含 preflight 状态与真实错误码）。

## 已知限制 / TODO

- 无序号标注、钉图不可二次编辑、文字提交后不可移动（重做=⌘Z 重画）。
- 重新编译后 ad-hoc 签名变化可能使屏幕录制授权失效，重跑一次授权流程即可。
- 改热键：改 `Sources/HotKey.swift` 里的 `keyCode`/`modifiers` 两行后 `make`。

## 验证记录（2026-10-08）

- `make`：swiftc 6.3.2（CLT，无 Xcode 全量）一次通过。
- `make selftest`：export.png 六种标注全部正确渲染（椭圆/箭头/矩形/画笔/马赛克/文字），Retina 2x 输出；view.png 完整界面（蒙层/镂空/手柄/尺寸标签/工具栏选中态/色板/线宽预览/动作键）渲染正确。
- `open ShotMark.app`：进程存活、后台进程名单可见 `ShotMark`、`pkill` 后 0 残留。
- **真机截屏链路已实测通过**：`--capture-test` 以 App 真实身份双屏捕获 OK（3840×2160 + 3024×1964），用户热键实机确认可用（「好像好了」）。
- 权限链路排障记录见上节（僵尸授权 / -3801 重开生效 / 自签名证书根治）。

## 项目沿革

- 2026-10-08：应用户要求从 PyObjC 方案推翻重写为 Swift 原生；初版曾短暂落 `dev/shotmark/`（独立 git，2 commits），用户拍板「按正常项目保存」后迁入 `work/shotmark/`，随 workspace git 全机同步。原 dev/ 目录与 raynor 上的 bare 备份仓已清理（迁移后由 workspace 同步承担备份）。
