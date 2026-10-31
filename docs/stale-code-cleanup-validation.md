# 过时代码清理验证

日期：2026-10-30。

## 变更

- 删除已停用的本地额度解析、缓存、模型归属和在线/本地合并逻辑，以及任务读取结果中无消费者的额度字段。日志继续读取任务模型、生命周期、token 与允许展示的进展。
- 删除本地额度专属测试和 `local-quota`、`stale-quota` 预览。多额度与模型预览改用通用夹具。
- RPC `initialize.clientInfo.version` 从应用的 `CFBundleShortVersionString` 读取。独立测试运行器无应用版本时使用 `unknown`；测试可注入版本。
- 诊断输出保留 `quotaSource` 字段：成功在线读取为 `network`，未读取在线额度时为 null。

## 保留的兼容与回归

- 旧 `rateLimits` 在线响应、动态 `rateLimitsByLimitId`、明确空响应、缺失字段及重置次数。
- 历史日志中的任意模型标识，包括已退役的 Spark。日志携带旧 `rate_limits` 不影响模型、生命周期和 token 解析。
- 超大及 UTF-8 跨块行、部分追加、文件替换/截断、缺失字段缓存、加强生命周期读取要求。
- 账号切换与认证变更失效、同账号网络失败保留已验证额度、限流退避、请求合并、第三方供应商隔离。
- 使用真实隔离日志读取器验证本地 token 更新可见，日志中的额度不覆盖在线额度。
- 既有供应商 schema 迁移、旧任务格式与归档/压缩日志兼容。

## 验证

- 完整测试：360 项 XCTest、35 项 Python 回归（24 项验证入口、11 项能耗脚本）、9 项隔离诊断、5 项语言检查全部通过。配置检查 80 项、0 失败；此模式跳过的 Release 检查由下列构建补齐。
  - 命令：`/usr/bin/python3 -I -B scripts/verify_local.py test`
  - 最终证据：`build/local-verification/20261030T061953Z-7142e018/`。最后通过固定入口复核，返回 `SKIP unchanged test`，复用相同源码、工具链及产物的完整通过记录，不算新执行。
- 未签名通用 Release 构建通过，包含 arm64 和 x86_64。Release 配置检查 93 项、0 失败；此模式不检查的测试宿主架构已由完整测试确认。辅助可访问性读取器编译通过。
  - 命令：`/usr/bin/python3 -I -B scripts/verify_local.py release-build`
  - 最终证据：`build/local-verification/20261030T062206Z-4dc7616f/`。
- 完整中英文布局生成通过，每种语言 470 张，共 940 张，另含状态栏等辅助位图。抽查英文浅色、中文深色多额度布局，通用模型标识正常显示。
  - 命令：`/usr/bin/python3 -I -B scripts/verify_local.py previews menu`
  - 布局证据：`build/local-verification/20261030T060849Z-9c589826/` 中的 `en/layouts.json`、`zh/layouts.json` 和相应 PNG。
  - 后续共享工作区仅更新了原生键盘焦点夹具，没有改变布局渲染代码；本项复用上述布局证据。
- **原生弹窗检查未通过**：上述命令随后在第一组 `native-menu-light` 的 Escape 关闭断言失败，整体结果为 failed。其余五种原生样式未继续执行，不能算作通过。
  - 日志记录 `active=false`、`key=false`、`appKey=nil`，但原生供应商按钮存在且成功设为 first responder。
  - 独立复跑 `/usr/bin/python3 -I -B scripts/verify_local.py previews menu --native-only` 得到相同失败：`build/local-verification/20261030T061548Z-4334b7b4/native-menu-light.log`。
  - 最终工作区的原生夹具含并行加入的应用激活和键盘窗口检查；本次临时添加的另一组激活步骤已撤回，保留并行改动。最终独立复核仍在焦点前置条件失败：`build/local-verification/20261030T062249Z-593b2451/native-menu-light.log`，错误为 `keyboardFocusUnavailable`，没有进入 Escape 路由检查。保留关闭断言，不将失败降级为通过。需在可取得键盘焦点的桌面会话补验。
- 最终残留扫描确认：生产源码、预览和通用测试不再引用 Spark、本地额度 API 或写死的 RPC `1.0.0`；Spark 仅保留在明确标注的历史日志回归中。旧发布说明保留历史事实。`git diff --check` 通过。

验证使用隔离夹具和未签名构建，不读取真实账号额度，不替换已安装应用。布局位图与固定弹窗检查不等于系统玻璃合成或完整 VoiceOver 验收。
