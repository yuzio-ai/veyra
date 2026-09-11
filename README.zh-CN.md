# Veyra

[English](README.md) · **简体中文**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/veyra-logo-preview-dark.png">
  <img src="assets/brand/veyra-logo-preview.png" alt="Veyra" width="360">
</picture>

Veyra 是使用 Swift 6 和 SwiftUI 编写的原生 macOS 菜单栏应用，用于监控 Codex 额度和本机任务。它集中展示额度窗口与重置时间，以及运行任务的状态、模型、耗时和 token 用量，不打断当前工作。

## 使用要求

- macOS 14 或更新版本。
- 已安装并登录 Codex 桌面端或 Codex CLI。
- 只有手动联网校准额度时才需要本机的 `codex` 可执行文件，无需填写 API Key。

## 安装

从 [GitHub Releases](https://github.com/yuzio-ai/veyra/releases) 下载最新压缩包，解压后将 `Veyra.app` 移入“应用程序”目录。从“应用程序”启动 Veyra；它只出现在菜单栏中，不显示 Dock 图标。

## 使用

Veyra 运行时，在任意应用中按 **Control + Option + V**（`⌃⌥V`）即可显示或隐藏面板；按 **Esc** 或点击外部关闭。在 **设置 → 快捷键** 中可以录入其他组合、关闭功能或恢复默认。组合须包含 Control、Option 或 Command，Shift 可选。录入时暂停当前快捷键，按 Esc 或离开录入控件取消；冲突会在设置中提示，并保留原有选择。无需辅助功能或输入监控权限。

点击菜单栏中的 Veyra 图标，可查看运行中的任务家族、任务状态、耗时、累计 token 和最新本地额度快照。需要与当前登录的 Codex 账号核对额度时，点击额度区域的刷新按钮执行联网校准。如果自动发现的 Codex 安装不正确，可在 Veyra 设置中指定可执行文件或数据目录。合法路径在按 Return、离开输入框或确认文件选择后自动生效；清空单个字段会恢复该字段的自动检测，“恢复自动检测”会清除两项手动设置。

Veyra 在启动和打开菜单时检查公开的 GitHub Releases，每 24 小时最多自动检查一次。可在“设置 → 软件更新”关闭自动检查，或点击“检查更新…”手动查询。发现新版后，“前往下载”会在浏览器打开对应版本页面。下载安装包后，退出 Veyra，再替换“应用程序”中的 App；Veyra 不会自行下载或安装更新。更新检查不使用 GitHub Token 或 Codex 凭据。

Veyra 以只读方式监控已有本地数据，不创建、恢复或控制任务，不触发模型请求，不复制凭据，也不修改 Codex 数据库和会话文件。

当一次成功的进程检查找不到匹配的 Codex 进程，且任务已连续 24 小时没有新的活动记录时，状态待确认的任务会被隐藏。仍有匹配进程的任务无论多久都保留；进程检查失败时保持原有的待确认状态和警告。这一显示过滤不会修改任务历史。

Veyra 支持简体中文和英文，默认跟随 macOS 语言偏好。可在 **系统设置 → 通用 → 语言与地区 → 应用程序** 中为 Veyra 单独指定语言，重新启动后生效。没有匹配语言时使用英文，日期和时间遵循系统区域设置。任务标题与 Codex 原始进展保留原文。

## 详细文档

- [使用指南](docs/user-guide.zh-CN.md)
- [数据、隐私与兼容性](docs/data-and-privacy.zh-CN.md)
- [开发文档](docs/development.zh-CN.md)
- [手动发布操作手册](docs/release.zh-CN.md)
