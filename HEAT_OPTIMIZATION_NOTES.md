# 0.9.58 Heat Optimization Notes

本分支只做耗电/发热路径优化，不改变多任务、Dock、键盘 Scene、触摸所有权、动画时长与最高刷新率策略。

## 已处理

1. **Release 默认关闭诊断链路**
   - `FLMEnqueueDiagnosticLine(...)` 在预处理阶段直接移除，热路径上的 `NSStringFromCGRect()` 等参数也不会再求值。
   - `FLMPublishDiagnosticEvent(...)` 在 Release 中变为 no-op。
   - SpringBoard 不再启动诊断文件 writer。
   - 如需抓日志，构建时加 `-DFLM_DIAGNOSTICS_ENABLED=1`。

2. **共享键盘状态写盘去重 + latest-state-wins 合并**
   - 旧实现每次调用都会因为 `updatedAt` 不同而触发一次 `NSDataWritingAtomic` 写盘。
   - 新实现先比较真实 payload；状态没变化就不写。
   - 写盘过程中如果连续收到多帧更新，只保留最新快照，避免串行队列积压几十/几百次原子写入。

3. **Darwin notify 去重**
   - keyboard avoidance / card geometry 状态完全相同时不重复 `notify_post`。

4. **锁屏检测热路径缓存**
   - `SBLockScreenManager` Class 与 4 个 selector 只解析一次，避免每个触摸样本创建数组和字符串。

5. **锁监控减少无效 WindowServer 事务**
   - `refreshWheelPriorityWindow` 只有值变化时才写 `hotspotsEnabled/hidden/windowLevel`。
   - 0.35 s 监控周期保持不变，并加 0.08 s timer tolerance 方便系统合并唤醒。

6. **圆角偏好缓存**
   - `cardCornerRadius` / `centeredCardWidth` 不再在 CALayer cornerRadius 热路径反复走 `CFPreferencesCopyValue`。
   - 设置变化通知到达时刷新缓存。

## 有意未改

- Dock 输入边界 `UIApplication -sendEvent:` 的同步 `notify_get_state`：这是触摸所有权机制的一部分。
- `CADisplayLink` 的最高刷新率请求、settle high-refresh lease、动画时长与手势阈值：保持 0.9.57 的交互机制和手感。
- Scene 生命周期、键盘配对、共享状态文件格式与通知名称均保持不变。

## 建议验证

重点对比以下场景的 SpringBoard CPU / Energy Impact：

- 挂靠卡片保留 5~10 分钟但不操作；
- 挂靠卡片存在时连续滑动底层 App 2~3 分钟；
- 连续拖动/缩放/隐藏/呼出卡片；
- 键盘显示、切换第三方键盘、关闭小窗；
- 关闭插件后待机对照。

如果优化后仍出现“操作结束后持续发热”，下一优先级是确认两个 `CADisplayLink` 是否在无手势/无动画时仍存活；这一步建议先做运行时计数，不建议直接改变 0.9.57 的高刷策略。
