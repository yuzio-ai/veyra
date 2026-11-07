# 设置窗口缩放与位置恢复

状态：方案已确认，已实施；首次作者检查见[验证记录](validation.md)，最小尺寸整改及真实拖拽结果见[补验记录](minimum-size-fix-follow-up.md)。未安装替换、提交、推送或发布。

## 确认与范围

用户于 2026-11-06 确认保留标准背景和现有默认尺寸，完善缩放、尺寸与位置恢复、小屏适配；随后明确要求实施完整计划。本方案保留单页的快捷键、Codex 路径、软件更新三组设置及原生控件。

不增加侧栏、标签页、设置项或半透明材质，不修改监控、路径校验、快捷键注册或更新检查逻辑。用户确认已解除首轮 design 草案的整体确认缺口；历史 design-01 保留原结论。

## 尺寸与布局

| 项目 | 规则 |
|---|---|
| 首次默认内容区 | 570 × 720 pt；标题栏另计 |
| 常规最小内容区 | 570 × 440 pt |
| 表单宽度 | 随窗口伸展，最大 720 pt，包含左右各 32 pt 留白；超宽窗口居中 |
| 留白及字体 | 上下 28 pt，现有组间距及原生字号保留 |
| 小屏 | 完整窗口不超出目标屏幕 visibleFrame；不足时下调有效最小尺寸 |
| 溢出 | 纵向滚动，不增加横向滚动或缩小字号 |
| 窄布局 | 低于 570 pt 时，快捷键及状态操作行改为纵向排列 |

尺寸是 Veyra 的内容适配选择，不是 macOS 统一标准。布局通过 AnyLayout 切换排列，保留字段、按钮和录制控件身份，避免为窄布局复制有状态控件。NSHostingView 嵌入普通 NSView 容器并随容器宽高伸展，AppKit 独立管理窗口最小尺寸；不将 hosting view 直接用作窗口 contentView，避免 SwiftUI 布局重写原生窗口尺寸边界。

## 窗口生命周期

- 继续使用普通 NSWindow 和现有 AppDelegate 单窗口复用方式。
- AppKit frame autosave 名固定为 `veyra.settings`，只写 Veyra 自己的窗口偏好，无旧格式迁移。
- 首次打开或无法恢复有效记录时使用默认尺寸，在鼠标所在显示器居中；没有匹配时回退到主显示器。
- 存在有效记录时恢复尺寸和位置；同进程关闭重开不重新居中。
- 按窗口与各屏幕可用区域的最大交集选目标屏幕；没有交集时按鼠标、主显示器、首个有效屏幕回退。
- 在创建、打开、窗口切换屏幕、显示器配置变化时校正完整 frame。只校正超界位置和过大尺寸，不因普通缩放重置默认值。
- 最小内容区根据可用区域扣除实际标题栏高度计算；回到大屏恢复常规最小尺寸。
- 窗口拥有通知观察生命周期。关闭时保存 frame 并移除本实现注册的观察；重开时重新注册，防止重复注册或误移除 AppKit 自己的观察。

内部建窗入口接收可选 autosave 名称。生产入口传入固定名称，预览默认不持久化，隔离恢复检查使用唯一名称并清理。

## 材质选择及取舍

设置使用普通语义窗口背景和原生控件，菜单继续使用系统 NSPopover。两种窗口的角色不同，无需相同透明度。推荐标准背景的收益是稳定阅读和输入；代价是不呈现与菜单一致的明显通透感。

普通模糊材质与 Liquid Glass 不等同。Apple 建议内容层使用标准材质，避免把整个表单做成 Liquid Glass。本轮不增加 NSVisualEffectView，不选用 popover、menu 或 HUD 材质模拟设置窗口。

来源（设计阶段通过 Context7 与 Apple 官方网页核查，实施阶段补查 AppKit frame API）：

- [Apple HIG：Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple HIG：Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Apple HIG：Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
- [AppKit：NSWindow frame autosave](https://developer.apple.com/documentation/appkit/nswindow)
- [AppKit：contentMinSize](https://developer.apple.com/documentation/appkit/nswindow/contentminsize)

## 实现与审查路径

窗口路径为菜单或 Command-逗号 → showSettings → SettingsWindow.make → prepareForDisplay → 关闭/重开；跨创建恢复及屏幕变化使用相同的几何约束。Core 的 SettingsWindowGeometry 负责可独立测试的屏幕选择和完整窗口约束，App 的设置窗口负责 AppKit 装配及生命周期。

ShortcutSettings、Codex 状态和更新状态共用 SettingsActionRow；原生输入框继续处理 Tab/Shift-Tab、Return、失焦提交、路径选择及关闭草稿重置。实施未改动这些业务方法。

作者检查不等同于独立 review。本轮 code 不自动启动其他 agent 或 closeout；后续 review 应核对固定候选中的上述调用方、控件身份、状态分支和通知清理，原实现者负责整改，原 reviewer 优先复查。

## 验收及证据边界

| 条件 | 方法及证据 |
|---|---|
| AC-1 首次默认值及屏幕可见性正确 | 缺失/无效 frame 的隔离窗口检查；Core 完整 frame 与标题栏几何回归 |
| AC-2 矮窗口可滚动访问全部设置 | 570 × 440 pt；中文和英文、错误及长提示夹具 |
| AC-3 宽窗口增加路径可见范围，表单宽度封顶 | 570、900、1100 pt 对照；400 pt 窄布局无横向溢出；控件和编辑器身份保持 |
| AC-4 重开、重新创建和显示器变化恢复正确 | 唯一 autosave 名称、重新建窗、保存记录缺失/无效、负坐标多屏和断开显示器回归 |
| AC-5 现有交互不回归 | 复用 SettingsInteractionChecks 的键盘、提交、录制取消及草稿重置 |
| AC-6 原生外观可读 | 双语、浅色/深色、增强对比度及滚动位图；降低透明度和人工操作证据单独说明 |
| AC-7 工程检查通过 | 固定入口完整 test、双语 settings 预览、Release build |

验证只使用隔离偏好和临时路径，不访问真实 Codex 账号。程序化原生控件检查不等同于人工键盘、VoiceOver 或真实跨进程重启验收；布局位图不证明合成器材质。实际执行结果、日志路径及缺口统一见验证记录，不以设计文档替代运行证据。
