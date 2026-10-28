# 五家 API 预置与本机钥匙串验证

2026-10-26。本轮保留工作区已有改动，未提交、推送、公证或发布。未修改真实 Codex 配置或登录凭据。

## 交付内容

- 普通设置固定显示 DeepSeek、Kimi、GLM、MiniMax、MiMo。填写 API Key、选择默认模型后，可保存或保存并启用。高级选项包含地址、目录允许的推理档位和来源；旧连接在高级管理中完整保留。
- API Key 仅保存至本机系统钥匙串，不同步 iCloud。界面不回填已有 Key。Codex 的 `auth.command` 使用 Veyra 可执行文件及不含密钥的引用；无界面分支在创建 NSApplication 前退出。
- 五家普通 API 使用国内端点和内置 Responses 模型目录。目录随应用发布，按版本保存，不运行供应商脚本。来源、核对日期和资源哈希见 [预置来源](provider-presets-sources.md)。
- schema 2 保留 schema 1 连接、最近一次撤销与中断恢复。替换 Key 生成新引用，保留当前配置、待确认记录和撤销仍需要的旧 Key。删除被引用 Key 会被阻止。旧环境变量连接不会读取环境变量，转换需要重新输入 Key。
- 启用、撤销及 OpenAI 回切继续使用配置 RPC 的版本检查和字段差异；保留 MCP、项目、审批、沙箱等无关配置。回切不修改 Codex 已有登录。移动应用后需重新启用，修复助手路径。

用户当前默认配置文件为 `/Users/zhubowen/.codex/config.toml`。应用仍尊重所选 Codex 数据目录及 `CODEX_HOME`。非敏感设置与恢复记录保存在 `~/Library/Application Support/Veyra/ModelProfiles/<数据目录哈希>/profiles.json`；权限为目录 `0700`、文件 `0600`。

## 验证结果

| 项目 | 结果与证据 |
| --- | --- |
| 全量测试 | 307 项 XCTest，无失败；隔离诊断、脚本检查及 80 项配置检查通过。`build/local-verification/20261026T134249Z-f2a1e661/` |
| 中英文与原生控件 | 中英文各 368 张布局，六种外观原生窗口检查全部通过。覆盖浅深色、增强对比度、降低透明度、滚动、收缩及 Esc；新版与旧连接控件均通过。`build/local-verification/20261026T134624Z-9dca2ae2/` |
| unsigned Release | `verify_local.py release-build` 通过，包含 Release 产物配置与辅助读取工具编译。`build/local-verification/20261026T135143Z-ac0f8357/` |
| 本地签名 Release | `delivery-signed-build.log` 构建成功；签名严格验证通过，arm64 + x86_64，版本 1.3.2 (6)。93 项产物配置检查无失败。日志在 `build/provider-credentials/` |
| 签名取钥链路 | `build/provider-credentials/20261026T134712Z/result.json` 通过。独立测试钥匙串、固定假 Key、Codex 0.154.0、临时数据目录及本地 Responses 模拟服务；实际加载应用内五家目录，完成 6 次本地认证请求。界面未启动，独立进程再次取钥成功；缺失和锁定时安全失败，用户钥匙串搜索列表未改变。 |
| 凭据泄露检查 | 元数据序列化和回滚夹具通过；额外扫描证据在 `build/provider-credentials/delivery-secret-scan.json`，覆盖临时 Codex 的 95 个持久文件及日志，未发现测试 Key。扫描夹具脚本保留在同目录 `verify_persisted_secret_scan.py`，对应签名集成记录为 `20261026T135025Z/result.json`。 |

事务回归覆盖：保存不启用、新 Key 写入失败、元数据保存失败清理新引用、Key 替换与撤销、依赖保护、冲突、提交后断线读回恢复、未保存编辑保护、未知认证拒绝复制、五家真实 `config/read` / `config/batchWrite` RPC（临时目录，无模型请求）。

原生控件夹具覆盖 SecureField 实际输入与清空、保存不启用、启用及取消/放弃未保存编辑。目录解析和请求协议另由签名验收通过实际 Codex 0.154.0 验证。后续版本仍需能力检测；本轮未宣称已验证其他 Codex 版本。

## 本地应用

- [签名通用 ZIP](../build/local-releases/20261026T134806Z-provider-presets/Veyra-1.3.2-provider-presets-macos-universal.zip)
- [签名应用](../build/local-releases/20261026T134806Z-provider-presets/Veyra.app)
- [版本、架构及 SHA-256](../build/local-releases/20261026T134806Z-provider-presets/manifest.json)

该副本与签名取钥验收的可执行文件 SHA-256 相同。签名使用本机开发身份；没有公证或发布。

## 证据边界

五家真实 API 调用均未验证：没有使用用户 Key，没有自动发起付费模型请求。目录校验与本地模拟请求不能证明供应商账户权限、真实网络连通或服务端行为。

签名钥匙串验收使用独立测试钥匙串，不把 unsigned 测试或普通位图当作钥匙串权限证据。原生窗口夹具覆盖六种外观；Esc 由已聚焦控件的窗口合成事件验证，不代表硬件键盘或 VoiceOver 人工验收。

早期失败的记录保留在 build 中，没有算作通过：目录资源缺失、必需目录字段缺失、Kimi 工具格式枚举不兼容，以及 SecureField 清空后的渲染时序，均已修复并重新验证。


## 代表截图

均使用固定示例数据，无真实 Key：

- [中文浅色设置](design/provider-presets/settings-zh-light.png) · [英文浅色设置](design/provider-presets/settings-en-light.png)
- [中文深色已配置](design/provider-presets/settings-zh-dark.png) · [当前供应商](design/provider-presets/settings-current.png)
- [助手路径修复提示](design/provider-presets/settings-repair.png) · [需要处理](design/provider-presets/settings-attention.png)
- [主面板入口](design/provider-presets/menu-current.png) · [英文降低透明度](design/provider-presets/settings-en-opaque.png)
