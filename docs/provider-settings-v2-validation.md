# Provider Settings V2 验证记录

> 历史验证快照：以下行为和证据对应记录日期的源码。当前操作以[使用指南](user-guide.zh-CN.md#codex-供应商)为准；后续修改需重新验证，不能将本记录作为当前源码已通过的证明。

2026-10-28。沿现有 SwiftUI、AppKit、配置 RPC 和 Keychain 实现渐进重构。保留工作区原有改动；没有提交、推送、公证、发布或修改真实 Codex 配置。

## 实现

- 一个服务商侧栏和详情工作区。官方 OpenAI 选择只导航，认证沿用 Codex 已有登录。自定义创建、重命名、复制和删除不再进入旧管理界面。
- 原生设置 Toolbar；1100 × 780pt 默认窗口、900pt 最小宽度；详情独立滚动。固定 Action Bar 在滚动区外，高级选项按连接保留会话内展开状态。
- 凭据、模型、高级选项、状态横幅和操作栏拆为组件。已保存 Key 只显示状态，不回填输入框。模型下拉和手动 ID 输入互斥；本地标识收进高级选项。保存基线参与 Observation，保存后按钮立即恢复未修改状态。
- schema 3 只持久化 `connections`。旧 `profiles`、`providers` 是兼容投影，不是两套存储。迁移保留本地 ID、Codex provider ID、凭据引用、旧官方方案、外部引用及恢复记录；同名或同地址不合并。首次写回前保留旧 schema 备份，编码后重新解码校验，再原子替换。
- 旧环境变量连接由用户明确转入 Keychain 时，同步兼容投影中的辅助路径与引用，保持原连接 ID 和 Codex provider ID，转换后仍可快捷切换。
- 非默认连接勾选“设为 Codex 默认”后才启用应用操作。保存只写 Veyra 元数据及用户指定的 Keychain 项。应用通过 `config/batchWrite` 和 `expectedVersion` 写用户配置，再读回确认。保留非目标字段；清除目标字段可能移除其附属注释，撤销不承诺逐字还原 TOML。
- 配置、默认、应用、编辑和连接测试分别表达。成功提示明确为新会话默认，既有 Codex 客户端可能需要重启。
- 自定义服务商支持无认证本地服务、模型列表和手动模型 ID。HTTPS 用于远程，HTTP 仅用于 localhost、IPv4 回环地址或 ::1；不追加 /v1，禁止重定向。地址变化后必须重新输入 Key 或明确确认旧 Key 可用于新地址。
- 列表获取和主动 Responses 测试分开。模型调用只在用户点击测试时发生，发送固定小请求，不携带工具或本地文件。测试结果按连接、地址、认证引用、协议和模型隔离，持久化固定分类和时间，不保存响应正文。
- 未测试的自定义连接可经警告确认后应用；明确协议不兼容或已知认证失败不能应用。模型能力不从名称推断；推理档位根据供应商元数据和 Codex 可接受值限制，已有配置仅用于对应模型的原有覆盖值。
- 无界面取钥进程在 NSApplication 前禁止 Keychain 交互；非交互查询同时设置 LAContext，不把 ACL 拒绝访问误报为仍可取钥。此策略只影响取钥辅助进程，不全局关闭 GUI 应用的钥匙串交互。
- App 移动修复只修改目标 `auth.command`，不带入草稿、模型或凭据替换。删除默认连接先应用替代配置；删除本地记录保留既有会话及恢复可能依赖的 Codex 定义和凭据。
- 可确认属于本次提交且字段值已知的部分写入，使用新版本检查回滚。外部修改或结果不明时保留 pending 与原撤销记录，阻止后续写入，等待用户修复并重新加载。
- 修复原有 RPC stdout 每个分块单独创建 Task 导致的交付乱序；改为 AsyncStream 单消费者顺序拼接，无配置写入重试。补充大 UTF-8 响应分块回归。

## 安全与证据边界

自动验收只使用临时 CODEX_HOME、固定假 Key、独立测试钥匙串及本地模拟 Responses 服务。真实供应商 API、账户权限、余额及完整工具能力不由这些夹具证明。

稳定签名验收覆盖 GUI 未启动时取钥、独立进程再次取钥、移动签名 App 后读钥与修复路径、缺失凭据、锁定钥匙串、拒绝读取的 ACL，以及临时 Codex 持久文件的假 Key 扫描。unsigned 构建只证明编译及夹具行为，不能替代系统钥匙串权限证据。

原生控件测试使用窗口及合成输入，不代表硬件键盘或 VoiceOver 人工验收。未修改系统辅助功能设置。VoiceOver 人工朗读、真实供应商调用仍需单独验收。

## 并发工作区

验收期间另有仪表盘改动加入共享工作区。其新 Core 文件曾导致配置成员检查失败；随后原生预览编译被同一文件的表达式错误阻断。本任务只为 `DashboardWorkspace.swift` 的 `??` 右侧布尔表达式补齐括号，没有改变仪表盘业务逻辑。此前失败和输入变化不会算作成功证据。

## 最终验证

以下为固定源码快照的最终证据。快照位于 `build/provider-settings-v2-validation-source/`，用于隔离同时进行的仪表盘写入；服务商相关 16 个源码文件的哈希与实际工作区一致，见 [源码清单](../build/provider-settings-v2-source-manifest.json)。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 完整 XCTest、隔离诊断及工程配置 | 371 项 XCTest，无失败；诊断和脚本检查通过，80 项工程检查无失败 | [test result](../build/provider-settings-v2-validation-source/build/local-verification/20261028T103029Z-cb8391c4/result.json) |
| 中英文布局与原生控件 | 每种语言 308 张，共 616 张布局；六种外观、900pt 窗口及原生交互通过 | [preview result](../build/provider-settings-v2-validation-source/build/local-verification/20261028T103421Z-c2d485fd/result.json) |
| Universal Release | arm64 + x86_64 构建通过，93 项产物配置检查无失败 | [release result](../build/provider-settings-v2-validation-source/build/local-verification/20261028T103141Z-5a7779cb/result.json) |
| 本地签名与独立取钥 | Codex CLI 0.154.0；7 次本地认证请求；移动后取钥及修复路径、独立进程再次取钥、缺失、锁定和 ACL 拒绝均通过 | [signed credential result](../build/provider-credentials/20261028T103431Z/result.json) |
| 凭据泄露扫描 | 扫描临时 Codex 的 97 个持久文件，没有发现假 Key；用户钥匙串搜索列表保持不变 | 同一 signed credential result |

原生控件回归包含：密钥安全输入及保存后隐藏、保存不应用、保存按钮清除修改态、官方 OpenAI 选择不写配置、未保存关闭保护、取消与放弃、统一创建自定义服务商、默认应用显式勾选、未测试应用确认、高级选项展开不移动 Action Bar，以及原生 Toolbar 和快捷菜单。

早期 ACL 拒绝夹具曾在 10 秒后超时，未算作通过。修复后对最终签名副本重新执行全部凭据检查；失败记录保留于 [修复前记录](../build/provider-settings-v2/denied-acl-before-fix.json)。RPC stdout 分块乱序导致的协议错误也已用顺序读取流及大响应回归关闭。

### 本地应用与截图

- [本地签名应用](../build/provider-settings-v2/Veyra.app) · [版本、架构、哈希和全部证据](../build/provider-settings-v2/manifest.json)
- [中文模型设置](design/provider-settings-v2/settings-zh-light.png) · [深色](design/provider-settings-v2/settings-zh-dark.png) · [英文](design/provider-settings-v2/settings-en-light.png)
- [创建自定义服务商](design/provider-settings-v2/create-zh-light.png) · [最小窗口](design/provider-settings-v2/small-zh-light.png) · [高级选项](design/provider-settings-v2/advanced-zh-light.png)
- [路径修复提示](design/provider-settings-v2/repair-zh-light.png) · [协议不兼容](design/provider-settings-v2/incompatible-zh-light.png)

版本保持 1.3.2 (6)。应用为本地 Apple Development 签名，启用 Hardened Runtime，没有公证或发布。交付二进制 SHA-256 为 `5722bf0f605fdf4a7ea7e42168d7d90e1aebe610f917684bf11990bfb8c72922`，与签名凭据验收记录一致。截图均为固定夹具，不代表真实账户或真实供应商调用。
