# DockToggle

一个 macOS 实用工具，将你的 Dock 变成开关——点击运行中 App 的图标来聚焦，再次点击 **隐藏** 或 **最小化** 它。

> 本项目完全由 **DeepSeek v4 Pro** 与 **OpenCode** 生成。  
> [English Documentation](README.md)

## 功能

- **隐藏模式**：点击已在前台的 App 的 Dock 图标，隐藏该应用程序。
- **最小化模式**：点击已在前台的 App 的 Dock 图标，最小化其最前面的窗口。
- 驻留在菜单栏中，无 Dock 图标（`LSUIElement`）。
- 通过菜单栏弹出窗口或设置窗口切换行为模式。
- 可选的登录时自动启动（`SMAppService`）。
- 实时引擎状态指示器和调试日志查看器。
- 多进程 App 支持（如快捷指令），通过 PID + Bundle ID + 本地化名称三层匹配。

## 系统要求

- macOS 14.0（Sonoma）或更高版本
- Apple Silicon（arm64）
- Xcode 命令行工具（用于构建）

### 所需权限

DockToggle 需要两项 macOS 权限才能正常工作。首次启动时会提示授权：

| 权限 | 用途 |
|---|---|
| **辅助功能（Accessibility）** | 检测 Dock 图标位置、识别图标对应的 App、对窗口执行最小化/恢复操作 |
| **输入监控（Input Monitoring）** | 通过 CoreGraphics 事件拦截全局鼠标点击事件 |

#### 如何授权

1. 启动 DockToggle，会显示权限警告。
2. 打开 **系统设置 → 隐私与安全性 → 辅助功能**，启用 DockToggle。
3. 打开 **系统设置 → 隐私与安全性 → 输入监控**，启用 DockToggle。
4. 重启 DockToggle。

> 如果已授权但仍无法使用，尝试从两个权限列表中移除 DockToggle，退出应用，然后重新添加并启动。

## 构建

```bash
./build.sh
```

构建产物路径为 `.build/DockToggle.app`。将其移动到 `/Applications` 文件夹并启动。

## 工作原理

1. 一个 `CGEvent` 拦截器全局捕获鼠标左键事件。
2. 鼠标按下时，判断点击位置是否在 Dock 区域内。
3. 如果点击的图标属于当前前台 App，则吞掉该点击事件并执行所选动作（隐藏或最小化）。
4. 否则放行点击事件让 macOS 正常处理，并加上 400ms 防抖防止误触发。

## 项目结构

```
Sources/
├── DockToggleApp.swift              # 应用入口、菜单栏 UI、生命周期
├── DebugLog.swift                   # 文件调试日志
├── SettingsView.swift               # 设置窗口 UI
├── SettingsWindowManager.swift      # 设置 NSWindow 管理器
├── Engine/
│   ├── EventTapEngine.swift         # 核心：CGEvent 拦截、点击处理
│   ├── DecisionEngine.swift         # 遗留决策逻辑（未使用）
│   ├── ActionExecutor.swift         # 通过 AppKit + Accessibility 执行隐藏/最小化
│   ├── DockInspector.swift          # Dock 进程解析、区域检测
│   ├── DockIconCache.swift          # Dock 图标位置/PID 缓存（1 秒刷新）
│   └── FrontmostTracker.swift       # 前台 App PID 追踪
├── Models/
│   └── BehaviorMode.swift           # 隐藏 vs 最小化枚举
├── Permissions/
│   └── PermissionsManager.swift     # 权限检查与请求
└── Settings/
    ├── ConfigStore.swift            # UserDefaults 持久化
    └── PermissionsGateView.swift    # 权限状态 UI
```

## 调试日志

调试日志写入 `/tmp/docktoggle.log`。可在设置窗口中查看最近 30 行。
