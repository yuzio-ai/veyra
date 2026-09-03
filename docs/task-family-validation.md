# 父子任务卡片验收

日期：2026-09-03。使用固定任务与临时数据库，不访问真实账号或修改 Codex 数据。

## 构建与回归

- `VEYRA_DERIVED_DATA_PATH=/private/tmp/veyra-task-family-tests ./scripts/test.sh`：69 项 XCTest 通过。
- `python3 scripts/test_diagnostics.py --app /private/tmp/veyra-task-family-tests/Build/Products/Debug/Veyra.app/Contents/MacOS/Veyra`：8 项独立诊断检查通过，包括父任务标题、子任务路径、角色及进展正文不泄漏。
- `./scripts/build.sh`：Release 构建通过，保留 macOS 14 部署目标与 Swift 6 严格并发检查。
- 初次受沙盒限制的 Swift 宏构建失败；放行后现有构建缓存中的测试包加载失败。独立构建目录完成全部测试，未修改工程配置以绕过检查。

新增回归覆盖任务家族分组、祖先缺失／归档、混合状态、多级关系、环与去重、名称回退、公开进展与工具回退、密文／继承消息过滤、轮次切换、半行追加、文件替换与截断。可选进展缺失不扩大扫描预算，无变化日志的读取字节数和打开次数保持为零。

## 界面

17 个固定场景 × 浅色、深色、两种高对比度，共 68 张布局预览通过尺寸检查。新增 `task-family`、`family-expanded`、`family-context` 覆盖默认两行进展、独立展开、父任务不运行及多级缩进。

真实 MenuBarExtra 的独立交互检查确认：初始都收起 → 只展开父任务 → 同时展开父子任务 → 收起父任务后子任务仍保持展开。任务行与卡片使用独立辅助功能容器，保留每个明细按钮的任务 ID。

浅色、深色、浅色高对比度、深色高对比度、浅色减少透明度、深色减少透明度均取得顶部／中部／底部、快速滚动和同一窗口动态收缩的通过结果。多任务窗口从 1,835pt 收缩到 503pt。

自动化期间部分尝试的弹窗在收缩检查前关闭，检查报告 `didNotShrink`，这些尝试不计为通过；复查取得完整结果。修改前保留应用与当前应用的浅色高对比度对照检查均通过。原始尝试和成功记录均保留。

## 产物与限制

- 构建和测试日志：`build/task-family-*.log`。
- 布局预览：`build/task-family-previews/`，尺寸记录为 `layouts.json`。
- 原生菜单布局位图、辅助功能状态和交互记录：`build/task-family-native/`，成功记录汇总为 `validation-summary.json`。
- 当前进程的屏幕录制权限检查返回 false，未请求或修改系统权限；布局位图无法验证完整 WindowServer 玻璃合成，最终玻璃效果仍需人工目视确认。
- 未替换用户正在运行的进程；重启 Veyra 后使用新构建的应用二进制。
