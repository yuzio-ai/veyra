# 历史归档

本目录保存已过时的设计记录与验证证据，仅用于追溯，不随当前行为更新。当前行为见[使用指南](../user-guide.zh-CN.md)、[数据与隐私](../data-and-privacy.zh-CN.md)，当前验证入口见[验证索引](../validation.md)。

归档规则：记录只对应其源码快照，其中的测试数量、界面尺寸、版本号和旧功能说明均不代表当前版本；发现与当前实现冲突时以源码和当前文档为准，不修改归档内容。

## 验证记录

| 文件 | 记录日期 | 内容 | 归档原因 |
| --- | --- | --- | --- |
| [dashboard-removal-validation.md](dashboard-removal-validation.md) | 2026-10-29 | Dashboard 移除范围与证据 | Dashboard 功能已移除 |
| [provider-removal-validation.md](provider-removal-validation.md) | 2026-10-31 | 服务商管理、取钥命令移除 | 功能已移除，迁移说明见[使用指南](../user-guide.zh-CN.md#旧版服务商功能迁移) |
| [stale-code-cleanup-validation.md](stale-code-cleanup-validation.md) | 2026-10-30 | 本地额度解析与旧代码清理 | 相关代码已删除 |
| [interrupted-session-cleanup-validation.md](interrupted-session-cleanup-validation.md) | 2026-10-31 | 中断会话遗留与服务商事务复查 | 相关代码已删除 |
| [dsh-only-experience-validation.md](dsh-only-experience-validation.md) | 2026-10-30 | 纯 dsh 体验 | 所述模型设置页与供应商入口已移除 |
| [quota-polling-validation.md](quota-polling-validation.md) | 2026-10-30 | 额度轮询与状态栏 | 按服务商屏蔽额度的行为已移除 |
| [menu-header-layout-validation.md](menu-header-layout-validation.md) | 2026-10-30 | 菜单顶部布局与本地交付 | 服务商下拉已移除，顶栏已改版 |
| [menu-card-hierarchy-validation.md](menu-card-hierarchy-validation.md) | 2026-10-30 | 菜单卡片层级、间距与按钮 | 布局在后续轮次继续调整 |
| [native-keyboard-validation.md](native-keyboard-validation.md) | 2026-10-30 | 菜单键盘焦点与 Escape | 结论已并入后续验证记录 |
| [project-task-grouping-validation.md](project-task-grouping-validation.md) | 2026-10-31 | 任务按会话项目分组 | 当前行为已写入使用指南与数据隐私文档 |
| [task-family-validation.md](task-family-validation.md) | 2026-09-03 | 父子任务卡片 | 被后续验证记录取代 |
| [reset-credits-validation.md](reset-credits-validation.md) | 2026-09-07 | 重置次数展示 | 被后续验证记录取代 |
| [energy-validation.md](energy-validation.md) | 2026-09-03 | 能耗优化验收与[测量数据](energy-measurements.json) | 测量对应旧版本 |
| [validation-log-2026-10-31.md](validation-log-2026-10-31.md) | 2026-10-31 | 原验证索引中的逐轮回归、原生外观与项目归属证据 | 从当前索引导出 |
| [validation-log-2026-11-01.md](validation-log-2026-11-01.md) | 2026-11-01 | API 参考费用实现、完整回归与界面焦点阻断 | 一次性源码快照，当前行为见使用指南 |
| [api-cost-focus-investigation-2026-11-01.md](api-cost-focus-investigation-2026-11-01.md) | 2026-11-01 | API 费用焦点交接、中文六种原生外观和长列表滚动、锁屏原因确认 | 独立验收快照，保留后续补验边界 |
| [api-cost-native-acceptance-2026-11-01.md](api-cost-native-acceptance-2026-11-01.md) | 2026-11-01 | 解锁后中英文完整菜单预览、十二组原生窗口外观与费用长列表滚动通过 | 最终补验快照，原生窗口与布局预览证据分别记录 |
| [api-cost-screen-input-acceptance-2026-11-01.md](api-cost-screen-input-acceptance-2026-11-01.md) | 2026-11-01 | 中文六种原生外观的屏幕观察、合成输入与实体键鼠反馈范围；声音审查跳过 | 独立记录屏幕、输入和辅助功能证据边界 |

能耗脚本本身仍在使用，方法见[开发文档](../development.zh-CN.md#能耗验证)。

## 已删除的退役资料

2026-11-01 清理时删除了 `docs/design/dashboard-workspace/`（已退役 Dashboard 的 README、验证记录、概念图与运行截图）和 `docs/design/provider-*` 空目录。相关内容属于已移除功能，仍可从本次清理前的 git 提交中恢复。
