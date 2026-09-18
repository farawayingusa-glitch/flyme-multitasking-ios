# Flyme Multitasking 0.9.72 - springboard scene bounds

以 0.9.63 竖屏稳定版为冻结基线，新增最小横屏路径：

- 横屏左右下角呼出轮盘，使用物理显示坐标和刘海安全区。
- 轮盘选择应用后直接打开左侧竖屏比例小窗。
- 横屏小窗固定左侧，不提供白条、挂靠、拖动、隐藏或横屏全屏 Handoff。
- 点击小窗外部空白直接关闭小窗。
- 横屏小窗宽度直接读取竖屏居中卡片设置。
- 系统键盘始终位于卡片上方，卡片不跟随键盘移动；微信自己负责输入框避让。

已保留 0.9.63 的满帧刷新治理、Scene 交还顺序、通知恢复和键盘路由修复。

0.9.65 修复首次横屏打开时安全区尚未稳定所导致的卡片刘海侧偏移，并把键盘事务期间偶尔回到竖屏坐标的系统触摸统一转换回物理横屏坐标，避免点外关闭误判卡片内部触摸。

0.9.67 撤回 0.9.66 中导致横屏 Hotspot 完全失效的入口重写，恢复 0.9.65 可触发的横屏轮盘路径；保留 0.9.66 中经过测量验证的横屏键盘 frame、交互区域和卡片实际几何修正。

0.9.69 将竖屏继续冻结在 0.9.63 路径，横屏改用独立物理坐标会话：全局与窗口两套横屏识别器只处理物理左下角/右下角，运行时验证 `current`、`fixed-left`、`fixed-right` 三种原始坐标模式并锁定本次会话模式。轮盘画布不再旋转竖屏窗口，左右两侧都按刘海安全宽度内缩，卡片关闭输入在轮盘选择手势结束后才重新启用。

0.9.70 修三个 0.9.69 实测问题。第一，0.9.69 只有轮盘窗口是物理 `844x390`，卡片窗口仍是 SpringBoard 的竖屏 `390x844`，再把 `844x390` 画布旋转 90° 塞进去，于是物理横屏屏上出现"竖屏窗口 + 旋转内容"。现在卡片、挂靠门、键盘转发窗口与轮盘共用同一个物理显示坐标空间，卡片仍按竖屏设置推导竖屏比例尺寸，只是不再旋转。第二，轮盘项中心不再直接写入容器坐标，改为经 `UIScreen.coordinateSpace` 从物理显示坐标换算到容器坐标，并在布局变化后按记录的物理中心重新同步；命中测试同时打印 window 坐标。第三，键盘不再丢弃竖屏坐标空间的 frame，而是把 `screen.coordinateSpace`、`screen.fixedCoordinateSpace` 与原始 frame 一起比较、取真正落在屏幕上的一帧；remote keyboard Scene 改用 `FBScene` 的 mutable settings 路由（`FBScene` 不实现 `updateClientSettingsWithBlock:`），并停止向目标 App 发布饱和的 607.68 避让值（键盘在卡片前置，微信自己处理输入框避让）。

新增诊断：`sb landscape-wheel-space` 打印 `windowScene.interfaceOrientation`、scene/window/root 变换、`screen.coordinateSpace.bounds`、容器在屏幕坐标空间的 rect 以及某个 item 的 window/screen rect；`sb notification=%@ rawFrame=%@ convertedFrame=%@` 打印键盘 frame 的换算结果；`sb scene-pair ... route=mutable-settings` 打印键盘 Scene 配对走的路径。

0.9.71 撤回 0.9.70 的坐标地基并修正轮盘分布与键盘坐标。0.9.70 把窗口改成物理 `844x390` 之后，`FLMConfigureVisualCanvas` 的「横屏视觉 + 竖屏 root」旋转分支永远不成立，于是系统那 90° 被原样输出，轮盘和小窗在物理横屏屏上一并变成竖屏形态 —— 这正是实测反馈的方向错误。现在窗口与各自的 root view 全部回到 SpringBoard 的 Scene 坐标（`FLMSpringBoardWindowBounds`），只把 presentation canvas 旋转进物理显示空间；画布旋转方向不再假定，而是配置完用 `screen.coordinateSpace` 实测一次原点落点，落错就翻符号重设，并打印 `sb canvas-verify`。轮盘分布改由统一的求解器算出：按刘海两测内缩得到安全盒，对每个半径求可用角窗 `spanMax(R)` 与最小间距所需角窗 `spanNeed(R)`，两者都不单调所以用 64 点扫描取仍满足间距的最大半径，单环放不下时按几何容量自然开第二环，圆心不再夹取，因此间距均匀且两侧都不压刘海。键盘转发窗口回到 Scene 坐标并在 root view 上套旋转画布，命中测试与 `FLMHomeDockWindow` 都先把窗口坐标换算到物理显示坐标；`keyboardFrameWillChange:` 改用本次会话锁定的横屏参考尺寸判定，不再实时重读会翻回竖屏的 `FLMVisualScreenBounds` —— 这是「键盘闪一下就没」的直接来源。

新增诊断：`sb canvas-verify canvas=%@ visual=%@ screen=%@ sign=%d rotated=%d corrected=%d` 验证画布旋转，`sb landscape-wheel-rings` 打印多环拆分，`sb kbd-discover` 打印远程键盘 Scene 的能力，`sb kbd-pair-attempt route=%@ error=%@ applied=%d` 打印配对异常文本，`sb kbd-hide-cause` 打印隐藏时的会话状态，应用侧打印 `[FlymeKeyboard] route-reload`。

0.9.72 修 0.9.71 实测暴露的真正根因：`FLMSpringBoardWindowBounds` 在这台设备上取的是 `[UIScreen mainScreen].bounds`，而它本身就等于物理横屏 `844x390`，不是假定的竖屏 `390x844`。日志两个独立探针点（`probeInWindow` → `probeInScreen`、`containerInScreen={{0,-454},{390,844}}`）都精确吻合同一映射 `screen = (wy, 390 − wx)`：SpringBoard 的窗口 scene 相对物理屏幕被系统整体转了 90°。用物理尺寸建窗口，它在屏幕上只覆盖左半屏，`FLMConfigureVisualCanvas` 的「横屏视觉 + 竖屏 root」分支条件 `width(root) ≤ height(root)+1` 因此永不成立 —— 实测 `canvas-verify` 出现 0 次，系统那 90° 被原样输出，轮盘与卡片一起呈竖屏。现在窗口改用 scene 尺寸（物理 bounds 的转置 `390x844`），窗口才真正覆盖整屏，画布旋转分支恢复生效，画布局部坐标重新恒等于物理显示坐标 `(u,v)`。新增 `sb canvas-anomaly root=%@ visual=%@ reason=root-not-portrait`：一旦该分支再次被跳过就直接报出根因，而不是只留下症状。

键盘侧本轮拿到了具体失效点：`sb kbd-pair-attempt route=mutable-settings error=FBScene has no updateClientSettingsWithBlock: applied=0`（20 次全失败），`sb kbd-hide-cause notification=UIKeyboardDidHideNotification pendingFrame={{0,70},{844,320}} visible=1` 随即被隐藏。本版先修窗口几何（键盘 Host 视图也挂在该窗口上），配对 API 留到下一版按这个错误改写。

保留功能：


- 竖屏系统底部上滑松手点越过屏幕中线后，将当前应用直接接入右上角最小挂靠卡片，不再经过居中模式或依赖多任务卡片数量
- 系统底部接入使用连续画面缩小与吸附；只有真实挂靠成功后才显示半透明勾号并反馈震动
- 键盘使用 SpringBoard 原生 Host 和键盘 Scene 配对，应用侧适配器按目标路由处理几何与输入隔离
- 居中模式上滑进入挂靠的行程缩短至 110pt，默认挂靠宽度重置为最小的 156pt
- Flyme 模式总开关
- 应用管理、锁屏项目与拖动排序
- 左右下角镜像轮盘
- 4、5、6……逐圈自动均摊布局
- 竖屏窗口重新布局
- UIKit 弹簧动画与选择触感反馈
- 滑动选中立即打开与固定轮盘点击打开
- 锁屏场景禁用和固定轮盘模态操作
- 0.3.4 的 58×65 触发区域、首帧抢占、轮盘布局和选择机制保持不变
- 轮盘半径与图标大小可调，可一键恢复 202pt / 56pt 默认值
- 居中小窗仅在所有触点从外部开始并构成点击时关闭；内部滑出、外部长按和外部拖动均不关闭
- 前台同应用重复选择只收起轮盘，避免同一主场景被全屏和小窗重复托管
- 白条按住后提供触感并严格跟手，卡片使用真实剩余距离连续展开
- 展开时应用场景切换为全屏逻辑尺寸并裁切显露，消除上下黑边
- 全屏覆盖画面保持到目标应用准备完成，隐藏第二段系统底部启动动画
- 居中小窗小白条上滑进入挂靠模式，支持左右上角自动吸附
- 挂靠卡片支持单击恢复居中、短长按浮起拖动及边缘隐藏/呼出
- 挂靠期间卡片外区域穿透，可继续操作当前桌面或前台应用
- 挂靠内容由透明操作层锁定，仅保留单击恢复居中和长按浮起拖动
- 挂靠模式不再保留独立的外围白色缩放柄，减少触摸入口和布局状态
- 居中小白条保持原外观并小幅扩大触摸区，上滑渐缩行程延长
- 挂靠卡片改由系统层从触摸起点接管，彻底隔离托管应用内容操作
- 挂靠及隐藏全程由目标应用进程的事件入口丢弃内容触摸，SpringBoard 仅保留拖动、单击恢复和向外隐藏控制
- 居中卡片上滑时围绕原中心四边同步缩小，达到阈值后以触感和半透明勾号确认挂靠
- 未达到阈值松手会弹性恢复；达标后向下撤回会淡出勾号、跟手放大并取消挂靠
- 挂靠卡片移动 5pt 即刻进入拖动，静止按住 0.10 秒亦可拖动
- 通过系统场景展示器托管可交互的居中小窗
- 小窗外轻微变暗、点按外部关闭、底部白条下滑恢复全屏
- 仅保护当前小窗应用的场景生命周期，创建失败时安全回退全屏

构建目标：

- iOS 16.0
- arm64
- arm64e
- `THEOS_PACKAGE_SCHEME = rootless`
