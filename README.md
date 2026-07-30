# Flyme 多任务

完全独立的 iOS 16 rootless 多任务插件工程。

当前 `0.1.1` 仅验证：

- 标准 Theos rootless 安装与卸载
- 独立 PreferenceLoader 设置入口
- SpringBoard 运行层连接状态

本版本不包含轮盘、小窗或手势功能，也不会修改 TrollOpen 的任何文件。

构建目标：

- iOS 16.0
- arm64
- arm64e
- `THEOS_PACKAGE_SCHEME = rootless`
