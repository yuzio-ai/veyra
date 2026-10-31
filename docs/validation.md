# 当前验证入口

当前功能为菜单栏额度与本地任务监控、单页设置。设置包含快捷键、Codex/dsh 路径及软件更新。Dashboard、服务商与模型管理、连接测试及取钥功能已移除，不能继续作为正向回归场景。

## 回归范围

| 入口 | 当前检查 |
| --- | --- |
| `verify_local.py test` | XCTest、隔离应用诊断、本地验证入口与能耗脚本回归、工程配置检查 |
| `verify_local.py previews settings` | 中英文单页设置、路径编辑、快捷键、更新状态、缩小窗口后的滚动 |
| `verify_local.py previews menu` | 中英文任务、项目分组、用量明细、额度、重置次数与来源状态；六种原生菜单外观的滚动、Escape 和焦点恢复 |
| `verify_local.py release-build` | 未签名通用 Release、产物配置与辅助工具编译 |

完整命令与隔离规则见[开发文档](development.zh-CN.md#codex-固定验证入口)。局部测试、`--native-only` 和 `--dsh-only` 各自保留独立范围，不能代替完整验证。`SKIP` 表示复用原成功证据。

## 界面与截图

- 从本次入口输出的 `build/local-verification/<run>/result.json` 确认范围与结果，再查看同目录的 `en/`、`zh/`、`layouts.json` 及原生交互 JSON。失败记录中的部分图片不能作为整轮通过证据。
- “当前版本”跟随本次构建；新版提示采用合成的下一补丁版本。任务标题、进展、路径和额度时钟均为可重复的示例，不读取真实任务或账号。
- 历史设计图、旧 `build/previews*` 目录和旧验证记录只对应当时快照。布局位图与合成事件不能证明系统玻璃合成、硬件输入或 VoiceOver 人工验收。

## 保留的兼容与拒绝测试

旧命令和旧场景仅用于验证启动前拒绝；不同服务商配置用于验证额度不再受模型配置影响。旧日志格式与模型元数据用于只读解析兼容；隐私测试验证凭据、标题和会话正文不会泄漏。这些测试不恢复已移除的功能。

## 历史证据

[服务商移除](provider-removal-validation.md)、[菜单卡片层级](menu-card-hierarchy-validation.md)、[菜单焦点](native-keyboard-validation.md)及其他 `*-validation.md` 均记录各自源码快照。历史测试数量、菜单高度和旧功能说明不代表当前行为。旧版本发布说明保持当时事实。

## 2026-10-31 预览残留复查

- 修复更新预览固定显示 1.1.0、提示更新至 1.2.0 的旧夹具；当前构建显示 1.3.2，新版示例为 1.3.3。增加 Bundle 版本一致性和新版比较检查，旧版或缺少版本的证据不计通过。
- 任务明细和任务家族预览改用监控相关的示例标题、路径与进展，移除个人资料编辑和 iOS 认证示例；清理 RPC 注释中的配置响应旧称。
- 修正任务明细文档仍写“待执行”及树状竖线的过时说明。新增本索引，明确当前检查与历史记录的边界。
- [完整回归](../build/local-verification/20261031T074031Z-967df8d7/result.json)：234 项 XCTest、29 项隔离诊断、5 项语言检查、35 项验证入口回归及 11 项能耗脚本回归通过；80 项配置检查无失败，Release 产物检查跳过。
- [中英文设置](../build/local-verification/20261031T074103Z-978fd2ec/result.json)：每语言 56 张布局、27 项原生设置检查通过；已目视核对英文浅色与中文深色更新状态图。当前版本与合成新版分别写入 `settings-native-checks.json`。
- [中英文菜单布局](../build/local-verification/20261031T074312Z-e2d97ec4/result.json)：每语言 212 项布局、7 项任务明细交互及四按钮的 Space/Return/原生按压计数检查通过；已目视核对英文任务明细与中文深色任务家族图。该轮随后在深色原生菜单的焦点宿主激活前置条件失败，整轮仍为失败，不计作完整预览通过。
- 首次菜单预览在按钮回调计数断言失败，见[失败记录](../build/local-verification/20261031T074214Z-ace3b6be/result.json)。复跑时中英文均得到 `[3, 3, 3, 3]` 且禁用按钮不响应；没有放宽断言或修改按钮实现。
- [原生菜单单独补验](../build/local-verification/20261031T074719Z-96655887/result.json)：浅色、深色、浅色高对比度通过；深色高对比度因前台切换而失败，日志为 `active=false`、`key=false`、`visible=false`，后两种降低透明度外观未执行。该次六种外观未全通过；后续修复与完整补验见下节。

## 2026-10-31 原生外观补验与焦点握手修复

夹具原先先写 `focus-request`，再激活宿主。宿主可能已响应请求并交出激活权，后到的激活调用又取消交接。Apple 的 [activate() 文档](https://developer.apple.com/documentation/appkit/nsapplication/activate())说明，激活已处于活动状态的应用会取消其待处理的激活权交接。

现在先等待宿主实际成为前台应用，再发送交接请求；宿主仅在自身确实位于前台时交出激活权。宿主日志立即写出请求、激活和 key 状态，失败日志记录抢占前台的应用标识。Escape 后宿主窗口可能不是 key，但宿主只提供激活权；正式菜单仍必须逐次证明自身 active、key、从后台打开、Escape 关闭及前台恢复，全部原断言保留。

| 焦点修复阶段检查（补充实际外观断言前） | 结果 | 证据 |
| --- | --- | --- |
| 完整回归与诊断 | 234 项 XCTest、29 项隔离诊断、5 项语言检查、35 项验证入口回归、11 项能耗回归通过；80 项配置检查无失败，Release 产物检查跳过 | [完整回归](../build/local-verification/20261031T075407Z-e6d542cd/result.json) |
| 英文原生菜单 | 六组交互通过；当时尚未校验实际 appearance | [英文补验](../build/local-verification/20261031T075438Z-97609802/result.json) |
| 中文原生菜单 | 六组交互通过；当时尚未校验实际 appearance | [中文补验](../build/local-verification/20261031T075559Z-d0df97af/result.json) |

12 组外观共覆盖 24 条 Codex／纯 dsh 的后台打开、实际激活与 key window、Escape 关闭及前台恢复链路，并覆盖顶部／中部／底部滚动、快速滚动、动态收缩与无数据源场景。结果逐项保存在各语言目录的 `native-*/menu-check.json`。本次使用 `--native-only`，不冒充重新执行全部布局渲染。

修复前与实施中的失败记录继续保留。日志曾明确观测到 `com.openai.codex` 抢占前台；焦点修复阶段的一次中文宿主启动也在就绪前被打断，见[启动失败记录](../build/local-verification/20261031T075522Z-a9d023c4/result.json)，随后重新完整执行中文六组交互通过。夹具不阻止外部应用切换，也不将焦点缺失降级为通过。

### 实际外观校验

目视复核发现，交互通过不能证明弹窗采用了指定外观。补充断言后，[失败记录](../build/local-verification/20261031T075854Z-da7cb049/result.json)明确复现 `requested=NSAppearanceNameDarkAqua`、`effective=NSAppearanceNameAqua`。NSPopover 默认使用浅色内容外观，因此只设置 NSApplication 的外观不足以覆盖弹窗继承。

固定菜单预览现在直接设置 `NSPopover.appearance` 及其窗口外观。原生检查在截图前核对实际 `effectiveAppearance`，将请求值、系统解析值、实际值、对比度和降低透明度夹具开关写入 `menu-check.json`；验证入口拒绝缺少或不匹配的证据。新增回归覆盖证据缺失、实际外观不符、解析结果不符和两种辅助显示标记不符。

当前系统将手动指定的高对比度 NSAppearance 解析为普通 Aqua／DarkAqua，记录中保留原始请求与解析结果；实际外观必须与解析结果一致，并严格核对浅深色归属。高对比度绘制继续由既有 `monitorPreviewContrast` 固定夹具覆盖；这不代表切换或验收了全局辅助显示设置。

| 最终检查（含实际外观断言） | 结果 | 证据 |
| --- | --- | --- |
| 完整回归与诊断 | 234 项 XCTest、29 项隔离诊断、5 项语言检查、36 项验证入口回归、11 项能耗回归通过；80 项配置检查无失败，Release 产物检查跳过 | [完整回归](../build/local-verification/20261031T080302Z-ea895498/result.json) |
| 英文原生菜单 | 六种外观夹具的实际外观、辅助显示标记、交互与焦点链路全部通过 | [英文最终补验](../build/local-verification/20261031T080336Z-220b2cec/result.json) |
| 中文原生菜单 | 同上六种夹具全部通过 | [中文最终补验](../build/local-verification/20261031T080414Z-1e88ad47/result.json) |

已逐项核对 24 条 Codex／纯 dsh 焦点链路，并查看英文深色不透明与中文浅色不透明截图，确认浅深色不同且正文可读。位图不包含完整 WindowServer 玻璃合成，硬件输入与 VoiceOver 不在本轮范围。失败与中间快照不代替上表最终记录。
