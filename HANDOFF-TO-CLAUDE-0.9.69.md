# Flyme Multitasking 0.9.69 交接文档

## 先读结论

这份文档给接手下一版的 Claude。不要在竖屏路径上做实验。用户从 0.9.63 起连续实测两天没有问题，0.9.64 到 0.9.69 的所有横屏改动都必须视为独立的实验分支。

0.9.69 已经解决：

- 竖屏冻结在 0.9.63 路径。
- 横屏轮盘的物理触发点已经正确，日志证明左下角原始触点会被 `fixed-left` 正确转换到物理左下角。
- 横屏关闭误触保护已经按新触摸流重新武装，日志中不再出现打开后 0.1 到 0.2 秒立即关闭。

0.9.69 仍失败：

- 轮盘虽然用 `844x390` 物理窗口计算，但用户看到的位置和方向仍是竖屏形态。
- 打开应用后卡片内容仍按竖屏 Scene 运行，用户看到的是竖屏内容。
- 键盘短暂出现后立刻隐藏，微信键盘无法正常使用。

这三项是下一版的核心任务，不要把它们混在一起猜。先修 Scene/坐标契约，再看轮盘视图树，最后处理键盘路由。

## 项目位置

- 当前活跃工作树：
  `C:\Users\Administrator\Documents\Codex\2026-09-17\new-chat-2\work\flyme-multitasking-ios-0.9.68`
- 主 Git 仓库：
  `C:\Users\Administrator\Documents\Codex\2026-09-07\ios-x20\work\repo`
- 当前分支：
  `codex/0.9.69-independent-landscape`
- 当前提交：
  `405a8eabc72bbf0b2603ca895d0d1b1cba408b2b`
- 稳定竖屏基线：
  `4094ca9` (`0.9.63-max-refresh-gestures-and-scene-handoff`)
- GitHub 仓库：
  `https://github.com/farawayingusa-glitch/flyme-multitasking-ios.git`

## 用户硬性要求

1. 竖屏必须与 0.9.63 保持一致，不能因为横屏逻辑改坏竖屏轮盘。
2. 横屏机制与竖屏完全独立，不能共享识别器的方向开关。
3. 横屏轮盘固定在物理屏幕左下角和右下角，左右横屏都要成立。
4. 轮盘要避开刘海。用户提供的最新日志中刘海在屏幕左侧，但下一版应同时避让左右两侧。
5. 横屏小窗固定左侧，保持竖屏比例的卡片，不跟着键盘上移。
6. 横屏不提供白条、挂靠、拖动、隐藏、横屏全屏 Handoff。
7. 点击卡片外空白关闭。
8. 横屏卡片沿用竖屏设置中的卡片宽度、上下裁切等数值。
9. 键盘必须在卡片前置，微信自己处理输入框避让。
10. 动画必须满帧，静止时允许降低刷新。

## 当前源码中的关键位置

以下行号基于提交 `405a8ea`：

- `Tweak.xm:46`
  横屏原始坐标模式枚举：`current`、`fixed-left`、`fixed-right`。
- `Tweak.xm:712`
  `FLMLandscapeVisualPointFromRawPoint`。三种原始坐标转换在这里。
- `Tweak.xm:735`
  `FLMLandscapeNotchAvoidanceInset`。左右对称的保守刘海避让。
- `Tweak.xm:1145`
  `FLMCornerGestureRecognizer` 保存第一原始触点和锁定模式。
- `Tweak.xm:2829`
  创建全局横屏识别器和 hotspot 横屏识别器。
- `Tweak.xm:3130`
  横屏全局识别器注册到 `_UISystemGestureManager`。
- `Tweak.xm:3254`
  `refreshWheelPriorityWindow`。竖屏和横屏识别器不再由方向状态互相关闭。
- `Tweak.xm:3469`
  `resolveLandscapeCornerGesture`。运行期尝试三种坐标模式，命中物理下角后锁定。
- `Tweak.xm:4431`
  `presentLandscapeWheelFromRight`。0.9.69 使用 `844x390` 窗口和 `overlayRoot`。
- `Tweak.xm:7042`
  `captureFloatingOrientationContract`。设置横屏会话尺寸和安全区。
- `Tweak.xm:9071`
  `floatingSystemSceneReferenceSize`。横屏分支当前返回 `FLMVirtualViewportWidth/Height`，也就是竖屏逻辑尺寸。
- `Tweak.xm:9297`
  `applyFullscreenSceneSettings`。日志 `landscape-scene-contract` 从这里发出。
- `Tweak.xm:9317`
  当前把 Scene interface orientation 硬编码为 `UIInterfaceOrientationPortrait`。

## 0.9.69 日志的直接证据

日志文件：
`D:\电脑软件\腾讯QQ\858601565\FileRecv\FlymeMultitasking-Diagnostic(4).log`

构建标记：
`Landscape Isolated Ingress 0.9.69 (physical coordinate session, notch avoidance)`

### 入口成功

关键行：

```text
1789721442.056 sb landscape-ingress accepted route=global-guard
raw={27.0,26.7} visual={26.7,363.0} mode=fixed-left fromRight=0
bounds={{0, 0}, {844, 390}} device=1
```

同一原始点连续被 `global-opener` 接受，说明：

- 全局横屏识别器可以在 SpringBoard 仍上报 `device=1` 的情况下工作。
- `fixed-left` 映射是正确的。
- 物理左下角触发不再是 0.9.68 的错误中间区域问题。

不要回退这部分坐标探测和锁定逻辑。

### 轮盘日志看似正确

```text
1789721442.191 sb landscape-wheel-present side=left bounds={{0, 0}, {844, 390}}
notchInset=51.0 safe={33.0,84.0,357.0,760.0} anchor={84.0,357.0}
radius=198.0 mode=fixed-left
rawInsets={47.0,0.0,34.0,0.0}
overlay={{0, 0}, {844, 390}} root={{0, 0}, {844, 390}}
```

并且后续点击：

```text
1789721445.101 landscape-wheel-item-select point={193.7,177.3}
selected=com.tencent.xin center={188.9,189.1}
```

数据层面轮盘的 window 和 root 都是 `844x390`，数学中心和点击点也一致。用户仍然看到竖屏形态，说明问题在“UIWindow/UIWindowScene 最终显示坐标空间”或“轮盘角度本身需要横屏化”，不能只看当前日志中的 `bounds`。

下一版必须补日志：

- `windowScene.interfaceOrientation`
- `window.transform`
- `rootViewController.view.transform`
- `window.screen.bounds`
- `window.screen.coordinateSpace.bounds`
- `[window convertRect:root.bounds toCoordinateSpace:screen.coordinateSpace]`
- 每个 item 的 `center`
- `[item convertRect:item.bounds toView:window]`
- `[item convertRect:item.bounds toCoordinateSpace:screen.coordinateSpace]`

优先参考历史 `Landscape.xm` 的：

- `wheelLocalPointForVisualPoint:`
- `synchronizeWheelItemLocalCentersWithReason:`
- `wheelItemNearWindowPoint:`

它使用 `UIScreen.coordinateSpace` 和 `convertRect:toView:`，而不是只相信 `bounds`。

### 应用卡片明确进入竖屏

关键行：

```text
1789721445.498 sb scene-frame policy=fullscreen
systemSceneReference={390.0000,844.0000}
contentViewportReference={390.0000,844.0000}
physical-card={282.0,565.3}

1789721445.498 sb landscape-scene-contract
frame={390.0,844.0} orientation=1 content={390.0,844.0}

1789721445.669 sb presenter-attached host=0xd46826a90
frame={{0, 0}, {390, 844}}

1789721445.670 sb content-scale policy=landscape-portrait-strip
systemSceneReference={390.0000,844.0000}
sourceStripWidth=390.00
targetPhysicalCard={176.1,353.0}
```

这不是猜测。当前源码明确做了两件事：

1. `floatingSystemSceneReferenceSize` 在横屏会话返回 `FLMVirtualViewportWidth/Height`，即 `390x844`。
2. `applyFullscreenSceneSettings` 把 `interfaceOrientation` 硬编码为 Portrait。

所以应用看起来是竖屏，是代码主动提交的结果，不是系统自动旋转失败。

下一版需要重新设计 Scene 和卡片内容的边界：

- 如果目标是“卡片内容保持竖屏比例”，不能只把 Scene 设成竖屏就结束。
- 必须把竖屏逻辑内容放进物理横屏卡片宿主，并单独处理键盘 Scene。
- 历史 `Landscape.xm` 的 `prepareScene:handle:` 同样把目标 App 设为 `390x844 + portrait`，但它额外提供了独立横屏卡片窗口和独立键盘窗口。当前代码缺少这部分完整隔离。
- 参考 `Landscape.xm` 的 `operationFrame`、`layoutHostView`、`beginKeyboardRouteForCurrentScene`、`prepareKeyboardWindowIfNeeded`。

### 键盘已经配对，但被隐藏

0.9.69 键盘序列：

```text
1789721450.393 notification UIKeyboardWillChangeFrameNotification
rawFrame={{0, 315}, {844, 75}} bounds={{0, 0}, {844, 390}} computedVisible=1

1789721450.403 host-native owner=sceneID:com.tencent.xin-...
keyboardScene=com.apple.UIKit.remote-keyboard
preferredHostClass=FBSSceneIdentityToken paired=1

1789721450.405 frame-apply inputVisible=1
inputFrame={{0, 315}, {844, 75}}

1789721450.936 frame-apply inputVisible=1
inputFrame={{0, 70}, {844, 320}}

1789721453.778 notification UIKeyboardWillChangeFrameNotification
rawFrame={{0, 390}, {844, 320}} bounds={{0, 0}, {844, 390}} computedVisible=0

1789721454.294 notification UIKeyboardDidHideNotification did-hide
```

同时有三条竖屏坐标 frame 被明确丢弃：

```text
keyboard-frame ignored=foreign-coordinate-space frame={{0, 769}, {390, 75}}
keyboard-frame ignored=foreign-coordinate-space frame={{0, 741}, {390, 103}}
keyboard-frame ignored=foreign-coordinate-space frame={{0, 524}, {390, 320}}
```

最关键的两个状态：

```text
adapter-handshake context=frame-visible app=com.tencent.xin
accepted=0 ctor={... pid:0 alive:0 valid:0}
ready={... pid:0 alive:0 valid:0}

keyboard-relation target=com.tencent.xin frontmost=com.bilibili.inter
appScene=sceneID:com.tencent.xin-...
keyboardScene=<none>
preferredHostClass=<none>
preferredHost=0x0
adapterAccepted=0 adapterPID=0
```

这意味着：

- SpringBoard 已经找到 remote keyboard host 并且 `paired=1`。
- 目标微信侧的键盘适配器没有接受本次 session。
- 键盘 frame 在横屏和竖屏坐标空间之间来回跳。
- 最终 SpringBoard 收到一个 `y=390` 的横屏 frame，判定 `computedVisible=0`，于是执行 hide。

下一版必须补日志：

- 原始 notification 的 `userInfo`
- `keyboardScene.coordinateSpace.bounds`
- `screen.coordinateSpace.bounds`
- `[screen.coordinateSpace convertRect:rawFrame toCoordinateSpace:window]`
- `[windowScene.coordinateSpace convertRect:rawFrame toCoordinateSpace:screen.coordinateSpace]`
- 目标微信进程是否真正持有 route 的 PID、session generation、scene hash
- `adapter-loaded` 事件的 PID 和 session generation

不要把 `rawFrame={{0,390},{844,320}}` 当作键盘真的隐藏。它很可能只是把“全屏高度”错误地当成了 frame 的 origin，因为当前 App Scene 是 `390x844`，物理 display 是 `844x390`。

### 关闭保护已经有效

0.9.69：

```text
1789721446.009 close-input armed generation=3 armAt=41193.631714
window={{0, 0}, {844, 390}}
```

之后用户是主动点击空白处才关闭：

```text
1789721469.535 touch-backdrop-began ... point={18.0,377.3}
1789721469.607 backdrop-ended ... authorized=1
1789721469.607 close-reason=backdrop-tap
```

因此下一版保留“先禁用关闭识别器，再在 0.55 秒后重新武装”的设计。不要恢复只比较时间戳的方案。

## 历史分支和成功构建方法

最值得参考的横屏历史分支是：

```text
a5804a1 Fix-landscape-wheel-sizing-keyboard-forwarding
```

之前的提交链：

- `923bee6` 独立横屏控制器
- `6cb34a9` 横屏轮盘入口路线
- `7559dba` 横屏轮盘几何和选择
- `ad9f894` 固定轮盘命中测试
- `910e4d9` 横屏 Scene 坐标会话
- `a5804a1` 横屏卡片尺寸和键盘转发

历史文件：

- `Landscape.xm`
- `FLMLandscapeRuntime.h`
- `scripts/verify-landscape.sh`

`scripts/verify-landscape.sh` 记录的硬性成功条件：

- `FLMLLogicalWidth = 390.0`
- `FLMLLogicalHeight = 844.0`
- `FLMLPhysicalDisplayBounds`
- `FLMLRawCoordinateModeCurrent`
- `FLMLRawCoordinateModeFixedLandscapeLeft`
- `FLMLRawCoordinateModeFixedLandscapeRight`
- `self.globalCornerGesture.enabled = configured;`
- `self.hotspotWindow.hotspotsEnabled = canSummon`
- `resolveAndPrimeGlobalCornerGesture`
- `item.visualCenter = center;`
- `synchronizeWheelItemLocalCentersWithReason`
- `convertRect:item.bounds toView:self.wheelWindow`
- `wheelItemNearLocalPoint`
- `UIKeyboardWillChangeFrameNotification`
- `_keyboardPreferredHostIdentity`
- `CGRectIntersection(self.cardContainer.frame`
- `restoreKeyboardLayerHost`

历史 `Landscape.xm` 里最重要的实现位置：

- `windowWithClass:frame:`：使用 foreground `UIWindowScene`，窗口 frame 直接设为物理 `displayBounds`。
- `prepareScene:handle:`：目标 App Scene 保持 `frame={390,844}`、`orientation=Portrait`。
- `operationFrame`：用物理 safeRect 计算左侧卡片。
- `wheelLocalPointForVisualPoint:`：用 `UIScreen.coordinateSpace` 将视觉点转到轮盘窗口和 `wheelContainer`。
- `synchronizeWheelItemLocalCentersWithReason:`：窗口布局变化后重新同步 item 本地中心。
- `beginKeyboardRouteForCurrentScene`：发布 identifier、scene、generation。
- `prepareKeyboardWindowIfNeeded`：为键盘单独创建物理横屏键盘窗口。
- `keyboardFrameWillChange:` / `keyboardDidHide:`：按物理显示处理键盘可见性，不把竖屏 frame 直接当成隐藏。

## 构建、上传、GitHub Actions、deb 下载

### 本地镜像和 SDK

- Python：
  `C:\Python314\python.exe`
- Logos：
  `C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\logos\bin\logos.pl`
- Logos lib：
  `C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\logos\bin\lib`
- iPhoneOS SDK：
  `C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\sdks\iPhoneOS16.5.sdk`
- Theos headers：
  `C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\theos-headers`
- CydiaSubstrate 补充头：
  `C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\build-include`

Logos 预处理示例：

```powershell
perl -I "C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\logos\bin\lib" ^
  "C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\logos\bin\logos.pl" ^
  -c generator=internal Tweak.xm > work-check\Tweak.mm
```

Clang 语法检查示例：

```powershell
clang -target arm64-apple-ios16.0 ^
  -isysroot "C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\sdks\iPhoneOS16.5.sdk" ^
  -I . ^
  -I "C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\build-include" ^
  -I "C:\Users\Administrator\Documents\Codex\2026-09-11\new-chat\work\theos-headers" ^
  -F "...\iPhoneOS16.5.sdk\System\Library\Frameworks" ^
  -F "...\iPhoneOS16.5.sdk\System\Library\PrivateFrameworks" ^
  -fobjc-arc -fblocks -fsyntax-only -Wall -Wextra -Werror=format ^
  work-check\Tweak.mm
```

同一命令需要分别跑 `arm64`、`arm64e`，并对 `Tweak`、`Keyboard`、`SceneLifecycle`、`Radius` 和设置页执行。

### Git push

主仓库在某些宿主机上会因为 owner UID 不同报 `dubious ownership`，可加：

```powershell
git config --global --add safe.directory "C:/Users/Administrator/Documents/Codex/2026-09-07/ios-x20/work/repo"
```

当前网络下普通 push 可能被 Schannel/TLS 阻断。实际可用命令：

```powershell
git -c http.proxy=http://127.0.0.1:7890 ^
    -c https.proxy=http://127.0.0.1:7890 ^
    push https://github.com/farawayingusa-glitch/flyme-multitasking-ios.git ^
    HEAD:refs/heads/codex/0.9.69-independent-landscape
```

### 触发 GitHub Actions

仓库里有两个活跃 workflow：

- `Build flyme radius extension`，ID `333344495`
- `Build flyme-multitasking`，ID `333344496`

0.9.69 使用第二个。原先 `gh` 直接调用时会遇到 EOF，因此用了旧的 helper：

`C:\Users\Administrator\Documents\Codex\2026-09-18\c-users-administrator-documents-codex-2026\work\github_build.py`

这个 helper 做的事：

1. 用 `git credential fill` 从 credential manager 取 GitHub token。
2. 写入 `GH_TOKEN`。
3. 设置 `HTTPS_PROXY` / `HTTP_PROXY` 到 `http://127.0.0.1:7890`。
4. 转发参数给 `C:\Program Files\GitHub CLI\gh.exe`。

触发命令：

```powershell
C:\Python314\python.exe ^
  "C:\Users\Administrator\Documents\Codex\2026-09-18\c-users-administrator-documents-codex-2026\work\github_build.py" ^
  workflow run "Build flyme-multitasking" ^
  --ref codex/0.9.69-independent-landscape ^
  --repo farawayingusa-glitch/flyme-multitasking-ios
```

本次运行：

- Run ID：`35325910222`
- URL：`https://github.com/farawayingusa-glitch/flyme-multitasking-ios/actions/runs/35325910222`
- 状态：success
- 耗时：约 `3m26s`

监听：

```powershell
C:\Python314\python.exe ^
  "...\github_build.py" ^
  run watch 35325910222 ^
  --repo farawayingusa-glitch/flyme-multitasking-ios ^
  --exit-status
```

下载 artifact：

```powershell
C:\Python314\python.exe ^
  "...\github_build.py" ^
  run download 35325910222 ^
  --repo farawayingusa-glitch/flyme-multitasking-ios ^
  --dir work\artifact-0.9.69
```

最终桌面 deb：

`C:\Users\Administrator\Desktop\flyme-multitasking_landscape-isolated-ingress-0.9.69_iphoneos-arm64.deb`

SHA-256：

`95B19775B35B1DFEB92973556B6B2B0DD7F5FFEC547D206655ACDBFB4FBDD294`

桌面只保留 0.9.69。旧 0.9.68 已归档到：

`C:\Users\Administrator\Documents\Codex\2026-09-17\new-chat-2\work\flyme-multitasking-ios-0.9.68\work\archive-0.9.68`

## 本地和远程验证

本地已通过：

```powershell
C:\Python314\python.exe scripts\verify-energy-repair.py --cc clang
powershell -ExecutionPolicy Bypass -File scripts\verify-lifecycle-repair.ps1
& "C:\Program Files\Git\bin\bash.exe" scripts/verify-frozen-foundation.sh Tweak.xm
```

远程 Actions 已通过：

- `scripts/verify-frozen-foundation.sh`
- `scripts/verify-energy-repair.py --cc clang`
- Theos/rootless/ldid 打包
- `scripts/verify-package.sh`
- artifact 上传

Deb 控制字段：

- Package：`com.codex.flymemultitasking`
- Version：`0.9.69`
- Architecture：`iphoneos-arm64`

## 下一版建议顺序

1. 先以 `a5804a1:Landscape.xm` 为参考，恢复独立的横屏窗口/Scene/keyboard 职责边界，不要在共享 `FLMWheelController` 里继续堆方向判断。
2. 用 0.9.69 的 `fixed-left/fixed-right` 探测作为入口，保持已经正确的物理下角识别。
3. 修轮盘显示：增加 window/root/item 的 screen coordinate 日志，确定是 Scene 旋转还是角度布局问题。优先复用旧 `wheelLocalPointForVisualPoint:` 和 `synchronizeWheelItemLocalCentersWithReason:`。
4. 修卡片 Scene：明确“物理 Scene 尺寸”和“竖屏逻辑内容 viewport”两层概念。不要再把 `systemSceneReference` 和 `contentViewportReference` 混成一个尺寸。
5. 修键盘：使用独立物理横屏键盘窗口或旧 `prepareKeyboardWindowIfNeeded` 的等价结构；不能让 `rawFrame` 的 `y=390` 被判成隐藏。
6. 最后重新验证关闭保护，确保只对“新触摸流”武装。
7. 测试顺序：先竖屏（必须与 0.9.63 一致），再刘海在左的横屏两个下角，再刘海在右的横屏两个下角，再开微信测卡片和键盘。

## 不要再做的事

- 不要为了让横屏触发而修改竖屏识别器的 `enabled`。
- 不要只改 `presentation-session landscape` 的方向枚举。
- 不要只改轮盘角度而忽略 UIWindowScene 的最终坐标空间。
- 不要把 0.9.69 的 `overlay/root` 都是 `844x390` 当成轮盘已经正确渲染的证明。
- 不要把键盘的 `y=390` 当成用户主动收起键盘。
- 不要在验证里只看源码字符串，必须结合新日志中的 raw point、mode、window frame、scene frame、keyboard frame。

## 常用日志检索

```powershell
rg -n "landscape-ingress|landscape-wheel-present|wheel-pinned|landscape-wheel-item-select" FlymeMultitasking-Diagnostic.log
rg -n "presentation-session|landscape-scene-contract|scene-frame policy" FlymeMultitasking-Diagnostic.log
rg -n "UIKeyboard|keyboard-frame|keyboard-relation|frame-deferred|frame-apply|frame-hidden" FlymeMultitasking-Diagnostic.log
rg -n "close-reason|close-input armed|touch-backdrop|exclusive-began" FlymeMultitasking-Diagnostic.log
```

如果 Claude 需要，当前源码分支已经推送到 GitHub，deb 也已生成。不要再从零重写横屏机制，先读 `a5804a1` 历史实现和 0.9.69 日志。
