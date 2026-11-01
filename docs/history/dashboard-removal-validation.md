# Dashboard 移除验证

> 归档文档（2026-11-01）：本文是历史验证记录，对应的源码快照、界面和测试数量均已过时。当前行为见[使用指南](../user-guide.zh-CN.md)，当前验证入口见[验证索引](../validation.md)。

日期：2026-10-29。

## 结果

- 移除整个 Dashboard：概览、关注队列、历史任务详情、统计分析、图表、筛选、期间比较、导出和索引管理。
- 删除 14 个生产 Swift 文件、4 个专用测试文件和 173 条专用本地化条目。保留的翻译内容未修改。
- 移除窗口生命周期、菜单栏统计按钮、应用菜单及 ⌘D、Dashboard 启动与预览参数；同步工程成员、验证脚本、规则模板和使用文档。
- 菜单栏额度、任务监控、任务家族分组及现有通用和供应商设置保留。监控使用的 `LocalTaskReader`、`RolloutReader`、`thread_history` 读取与轮询未移除。
- 旧 `~/Library/Application Support/Veyra/History/index.json` 保留；当前版本不再创建、读取、更新或清除此索引。本次未操作旧索引或用户导出文件。
- 历史设计和验证资料保留，并标记为已退役。

## 分析页入口核查

核查安装版 ChatGPT/Codex 26.1023.50603（22391）的随包深链接解析器。设置路径白名单不包含 `usage` 或 `analytics`；在独立 Node 进程中执行其原始设置解析函数，以下链接均得到 `{"kind":"settings"}`，没有分析页路径或查询参数：

- `codex://settings/usage?tab=analytics`
- `codex://settings/analytics`
- `codex://settings?tab=analytics`

因此未加入快捷入口。没有通过模拟点击实现跳转。计算机使用工具禁止访问 `com.openai.codex`，未进行真实 UI 跳转验收；上述证据仅证明所测链接的解析行为，不声称覆盖所有内部导航方式。

官方设置深链接参考：[Commands / Settings](https://learn.chatgpt.com/docs/reference/commands#settings)。本地解析记录：[codex-analytics-route-check.json](../../build/local-verification/codex-analytics-route-check.json)。

## 验证

| 检查 | 结果 | 本地证据 |
|---|---|---|
| 全量 XCTest、隔离诊断、验证脚本、工程配置 | 319 项 XCTest 零失败；诊断、19 项 Python 回归及配置检查通过 | [20261029T070834Z-9cf54e4e](../../build/local-verification/20261029T070834Z-9cf54e4e/result.json) |
| 中英文菜单和设置布局 | 每语言 440 个场景，共 880 个；抽查菜单和供应商设置画面 | [20261029T070932Z-61213c32](../../build/local-verification/20261029T070932Z-61213c32/result.json) |
| 原生菜单固定夹具 | 浅/深色、高对比度浅/深色、降低透明度浅/深色六种状态通过；含溢出滚动、内容收缩、切换和 Escape 检查 | 同上 |
| 无签名 Release | arm64＋x86_64 构建、合并 Info.plist、发行配置和辅助功能读取工具编译通过 | [20261029T071519Z-7cadb95a](../../build/local-verification/20261029T071519Z-7cadb95a/result.json) |
| 验证规则模板 | 13 项边界检查通过；未安装或修改已加载的项目规则 | `install_verification_rules.py --check` |
| 残留与差异检查 | 生产源码与工程无 Dashboard 类型、历史索引或 Charts 引用；`git diff --check` 通过 | 源码检查 |

以上原生交互使用隔离夹具，不代表真实账号联调或 VoiceOver 验收。Release 为无签名验证产物；未安装、发布或替换现有应用。
