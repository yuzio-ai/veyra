# 设置窗口原生工具栏

## 实现

- 使用两个标准 `NSToolbarItem`：`veyra.settings.general`（`gearshape`）和 `veyra.settings.models`（`cpu`）。
- `.expanded` 工具栏样式，显示独立标题栏，窗口控制按钮位于标题栏左上方；配合原生工具栏和 `.iconAndLabel`，由 AppKit 提供图标在上、名称在下的布局和选中态。两个项目居中，不设置自定义视图、宽度或背景。
- 项目名称复用现有本地化。macOS 15 及以上关闭显示模式自定义；保留 macOS 14 部署目标。
- 当前页面由 `CodexModelProfilesStore.tab` 决定。Observation 同步外部页面切换及忙碌状态，控制器观察回调弱引用自身。
- 点击项目仍通过 `navigate`。当前项目点击不提示，忙碌或未保存确认期间拒绝重复导航；取消和保存失败保持原页面与原选中态。
- 移除旧的分段导航。模型预览复用实际工具栏控制器，并保存整个原生窗口视图的位图。
- 设置预览和工具栏交互检查复用固定路径及配置报告夹具，不调用真实配置检测；不写 Codex 配置或真实凭据。

## 验证覆盖

`ModelProfileWindowChecks` 增加原生 target/action 检查：两个方向切换、外部状态切换及重新显示、忙碌拦截、当前页点击、确认期间重复动作、取消、放弃、保存成功及保存校验失败。

`ModelProfilePreviews` 覆盖中英文、通用和模型两个页面、浅深色、高对比度及内容不透明回退。正式窗口、预览及交互检查共用 `SettingsWindow.make`，最小内容为 900 × 600；原生标题栏和工具栏另计。Hosting view 仅发布最小尺寸，不发布最大尺寸或固有尺寸约束。检查两个页面在 1280 × 900 和 950 × 650 内容尺寸下均能放大、缩小，并确认最大尺寸未被内容锁定。通用内容保留滚动，模型表单保留现有滚动和底部操作区。

验证命令使用项目固定入口：

```sh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews settings
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py release-build
```

## 证据边界

- 窗口位图包含 AppKit 实际构造的标题栏和工具栏，不是图像生成设计稿；位图不等同窗口合成器对玻璃、阴影和透明度的最终显示。
- 不透明回退针对固定预览环境；没有修改系统辅助功能偏好，不能据此宣称系统“减少透明度”已完成人工验收。
- 原生交互检查通过 AppKit target/action 和实际确认按钮执行，不代表硬件鼠标、键盘或 VoiceOver 人工验收。
- Release 验证为无签名构建，不代表签名、发布或真实 Keychain 验收。

## 执行记录

- [完整测试记录](../build/local-verification/20261030T055008Z-80242de8/result.json)：377 项 XCTest、隔离诊断和配置验证通过。该记录属于共享工作区的已有成功证据，本次核对不算一次新测试。
- [Release 记录](../build/local-verification/20261030T054307Z-9367d4e2/result.json)：无签名通用 Release 构建、93 项配置检查及辅助功能读取工具编译通过。
- [最终设置预览目录](../build/local-verification/20261030T055525Z-739a7d42/)：英文、中文各生成 318 张布局位图，两种语言的原生工具栏交互检查均通过，最小窗口实际为 900 × 688。
- 专项检查结果：[英文](../build/local-verification/20261030T055525Z-739a7d42/en/settings-toolbar-native-checks.json)、[中文](../build/local-verification/20261030T055525Z-739a7d42/zh/settings-toolbar-native-checks.json)。
- 已目视核对浅色通用页、深色高对比度模型页和两个最小窗口页面；[中文实际窗口位图](../build/local-verification/20261030T055525Z-739a7d42/zh/models-general-light.png)。

**整体验证限制：** 工作区还有其他会话持续修改项目归属、供应商界面、诊断及测试相关源码。设置预览中的所有命令虽然分别通过，但入口最终检测到输入变化，将整轮结果标为 `failed` / 不可复用。完整测试和 Release 的上述成功记录只证明各自记录对应的源码快照，不能证明后续并发修改。需在工作区输入稳定后重跑最终整体验证；没有放宽输入指纹或锁规则。

## 窗口与服务商交互修正（2026-10-30）

- 三个窗口控制按钮回归独立标题栏，保留原生定位；启用最小化、缩放及边框调整尺寸。
- 移除侧栏底部“管理”菜单和配置导入入口；外部配置变化继续由已有监控自动同步。自定义服务商的重命名、复制和删除仍在其右键菜单中。
- “高级选项”使用一整行 Button 作为 DisclosureGroup 标题，箭头、标题和行内留白均触发同一个展开动作。交互检查验证箭头、标题和留白命中同一个原生按钮，target/action 可以展开、收起，且底部操作栏位置不变。
- 最终完整验证：[20261030T143431Z-cca354c6](../build/local-verification/20261030T143431Z-cca354c6/result.json)，376 项 XCTest、隔离诊断、脚本回归及配置验证通过。上文执行记录仅代表各自历史源码快照。
- 原生检查：[窗口与工具栏](../build/local-verification/20261030T143219Z-96794273/zh/settings-toolbar-native-checks.json)、[服务商与高级选项](../build/local-verification/20261030T143219Z-96794273/zh/model-profile-native-checks.json)均通过。两个页面验证了放大、缩小和未被锁定的最大尺寸；实际最小外框为 900 × 679。
- 中英文预览命令及单项原生检查均通过；中文最终预览也完成。两次整轮预览因其他会话在运行期间修改菜单玻璃、项目任务、本地化或交互检查源码，被入口标记为 `failed` / 不可复用，不能宣称整轮预览获得成功快照。最后一次完整测试已在这些修改后通过。
- 已目视检查浅色新增服务商、深色高对比度最小模型窗口及[中文通用页](../build/local-verification/20261030T143219Z-96794273/zh/models-general-light.png)。未做硬件鼠标边框拖动或 VoiceOver 人工验收。
