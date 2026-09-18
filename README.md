# Flyme Multitasking 0.9.74 - display space unification

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

0.9.73 修 0.9.72 实测反馈的三个问题。第一，第一次横屏呼出画出来仍是竖屏轮盘：根因是自校正发生在 `overlayWindow.hidden` 还是 `YES` 的时候，此时 `UIScreen.coordinateSpace` 读不出有效落点，`FLMCanvasOriginLandedOnFarCorner` 拿不到正确符号，错误符号被当成正确结果接受（`corrected=0`）。现在初始方向不再猜，直接取本次会话锁定的 `landscapeIngressRawMode`；并在 `overlayWindow.hidden = NO` 之后立刻重新执行一次 `FLMConfigureVisualCanvas`，让校正发生在窗口可见、屏幕坐标空间真正有效的时刻。第二，图标离物理屏幕边缘太远：两个数值原因 —— 51pt 的刘海内缩被同时加到左右两侧（实测 `safe={33,84,357,760}`、`anchor=(84,357)`），把轮盘从干净的那一侧推离边缘整整 51pt；72° 弧度上限又让弧线提前收尾（最上面图标停在 `x=145`）。现在按锁定的横屏方向逐侧计算 housing 内缩（刘海在左就只缩左、刘海在右就只缩右），并且横屏允许用满整个可行象限（`M_PI_2`），于是 `R ≤ H` 且 `R ≤ V` 时弧线正好取 `[-π/2, 0]`，两个端点精确贴住呼出侧物理边缘与底部边缘，"贴着真实屏幕的左侧和底部"由几何保证而不是靠调参。第三，小窗显示正确但键盘仍然无法调用：日志证明系统其实早已把远程键盘 Scene 配对到卡片 Scene（`host-native paired=1` 十条、21 次 `host-update enter`、0 次拒绝或推迟），失败点不在这里；真正的问题在应用侧 —— 整份日志里 `role=application` 的 `route-reload` 事件为 0 次，`sb adapter-handshake ctor={reg:0} ready={valid:0}` 说明目标门控初始化从未运行。根因是 `FLMReloadKeyboardRoute` 的缓存版本门：`FLMKeyboardSharedCacheRevision` 只在物理重读 plist 时前进，一份缓存快照会让目标更新被永久吞掉。现在改为直接比对已解析的 route tuple（`targetHash` / `sceneHash` / `sessionGeneration`），并新增 `route-tuple` 诊断事件（`a` = 发布方 targetHash 低 16 位，`b` = 本进程自身 hash 低 16 位），下一份日志可直接判断是 hash 不匹配还是刷新根本没触发。同时 `setFloatingKeyboardPreferredHostIdentity:scene:outReason:` 不再返回硬编码文本，`kbd-pair-attempt` 打印真实失败原因。

新增诊断：`sb landscape-wheel-present` 增加 `orientation`、`housing={左,右}`、`safe={上,左,下,右}` 字段，可直接核对两侧内缩是否对称、弧线端点是否落在物理边缘；应用侧新增 `route-tuple` 事件。

0.9.74 修 0.9.73 实测反馈的三个问题，并把坐标换算从「按方向猜」改成「按实测恒等式算」。

第一，第一次打开应用小窗偶尔反方向。日志给出了完整证据链：`sb canvas-verify` 在窗口还不可见时打出 `canvas={{0,0},{390,844}} sign=-1 corrected=0` —— 画布在物理屏上仍是竖屏形态 `390x844`，而判别函数 `FLMCanvasOriginLandedOnFarCorner` 只在两个角落之间比距离，一个尚未摆正的画布同样"落在远处"，于是被误判成正确符号（`corrected=0`）；紧接着卡片就在这块错画布上打开（`presentation-session` → `centered-open`），直到用户把卡片关掉之后才出现 `corrected=1` 的正确画布。现在判别不再比角点距离，而是直接量画布在屏幕坐标空间里的包围盒：正确画布必然是横屏 `844x390`，宽高比反过来就是错的；同时画出包围盒尺寸在样例里对两个符号完全相同（都是 `844x390`），也就是说旧判别用的信息量根本不足以区分符号，这是它必然误判的证明。

第二，小窗点空白处无法每次都关闭、卡片内容触摸也不可靠。根因与第三点同源：`FLMVisualPointFromRootPoint` 按 `orientation` 选旋转分支，而本机日志证明该函数的画布局部坐标恒等于物理显示坐标（画布局部点 → 物理点 `(32.3,368)`、`(84,159)` 两组独立探针都精确吻合），方向根本不影响结果。用方向去挑分支，等于用一个无关变量决定对错。现在该函数改写成实测恒等式 `visual = (visualW/2 + dy, visualH/2 - dx)`，不再读 orientation；陪跑的 `convertedFrame={{0,0},{320,390}}`（应为 `{524,0,320,390}`）正是这个错误分支的产物，而它直接被写进 `floatingBackdropTap.additionalProtectedFrame`，于是真实空白处被当成键盘区域保护起来，`inKeyboard=1` → `UIGestureRecognizerStateFailed`，空白点击无法关闭。修好换算后保护框与真实键盘位置一致，空白点击恢复正常。

第三，小窗无法调用键盘。用户给出的可接受方案是「调用竖屏键盘、靠右贴住屏幕边缘」，本版按此实现：目标应用在自己竖屏 Scene 契约里抬起竖屏键盘（`rawFrame={{0,524},{390,320}}`），经实测恒等式换算后在物理屏上正好是右边缘的一条通高竖带 `{524,0,320,390}` —— 这正是用户要的效果。键盘可见时，卡片不再与键盘重叠（改到键盘带左侧），`floatingKeyboardInteractionFrame` 与转发窗口的命中框都用同一条通高带，键盘可见性判定也改用本次会话锁定的纵向/横向参考尺寸，不再实时重读会翻回竖屏的 `FLMVisualScreenBounds`。

新增诊断：`sb canvas-verify` 的 `canvas` 字段现在直接给出画布在屏幕坐标空间的包围盒（横屏 `844x390` 即正确）；`sb notification=%@ rawFrame=%@ convertedFrame=%@` 在横屏下应打出 `convertedFrame={524,0,320,390}`。

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
