# 供应商模型实时获取验证

2026-10-26。保留工作区已有改动；未提交、推送、公证或发布，未修改真实 Codex 配置或登录凭据。

## 行为

- 应用只预置五家供应商的地址、认证和协议适配，不再打包模型清单、固定默认模型或按模型硬编码的能力目录。首次保存 Key 后获取列表，用户自行选模型，再保存并启用。供应商返回的新模型无需更新应用即可选择。
- 第一次保存或替换 Key 自动获取一次；仅修改模型不重复请求。刷新按钮单独获取列表。打开设置、启动应用、菜单切换不自动获取，不自动选择第一项。
- Key 和设置先本地保存；请求失败不回滚保存，也不修改 Codex。模型列表与模型推理分别表达状态，不把列表成功当作推理、余额或工具调用成功。
- 首次无列表不能启用。网络、超时、限流或服务故障可以使用匹配缓存；认证失败或无效响应禁止启用，保留缓存供查看。返回空列表与错误分开显示；原选中模型消失时要求重新选择。
- 缓存按 Codex 数据目录、供应商、基址和凭据引用隔离，保存规范化模型字段、最后成功时间和固定错误分类。缓存损坏视为尚未获取，不隐藏已保存 Key；再次获取可恢复。
- 缺失能力跟随 Codex 默认值，不推断上下文或推理档位。高级选项支持手动覆盖。API 返回的提示词、审批、脚本和代理规则不会导入，异常响应回显的凭据也不能进入模型缓存。
- 新目录由获取结果生成，按内容哈希保存为不可变文件。旧目录、当前配置、Key、撤销和恢复记录保留。刷新不会覆盖旧目录或改写 Codex 配置。
- 切换供应商、改变地址、开始替换 Key、关闭页面及关闭设置窗口均取消请求；迟到响应不能覆盖其他连接。未保存编辑保护保持有效。

## 接口与边界

五家使用各自 HTTPS 基址追加 `/models`，只向保存的地址发送带 Bearer 认证的 GET 请求，不尝试其他域名。临时 URLSession 不使用持久 HTTP 缓存、Cookie、自动认证存储或重定向；15 秒超时，2 MiB 响应上限，不自动重试。

| 供应商 | 解析与官方资料 |
| --- | --- |
| DeepSeek | `data[].id`，可选上下文、模态及 effort。[官方列表接口](https://api-docs.deepseek.com/api/list-models/) |
| Kimi | `data[].id`，可选上下文及输入能力标记。[国内官方接口](https://platform.kimi.com/docs/api/list-models) |
| GLM | `data[].id` 或 `models[].slug`；处理 HTTP 200 中的明确认证错误。[Responses 基址](https://docs.bigmodel.cn/cn/guide/develop/responses/introduction) |
| MiniMax | `data[].id`。[国内官方接口](https://platform.minimax.cn/docs/api-reference/models/openai/list-models) |
| MiMo | `data[].id`，保留供应商级 Responses Lite 适配。[官方列表接口](https://mimo.mi.com/docs/en-US/api/model/list-models) |

响应保留顺序及大小写，按精确 ID 去重；没有模型白名单或名称前缀筛选。所有有效返回项都展示，包括没有完整能力元数据的项，因此列表出现本身不保证能作为 Codex 的代码模型使用。GLM 已用无 Key 请求确认接口要求认证，成功格式仍须真实 Key 验收。

## 验证证据

| 检查 | 结果 |
| --- | --- |
| 最终完整测试 | 325 项 XCTest 无失败；隔离诊断、脚本及 80 项配置检查通过。`build/local-verification/20261026T151946Z-3fcb3045/` |
| 最终中英文及原生预览 | 中英文各 398 张布局，原生设置和六种外观菜单交互全部通过。`build/local-verification/20261026T152113Z-fb2be11e/` |
| unsigned Release | Release、产物配置及辅助读取工具构建均通过。`build/local-verification/20261026T152821Z-a87b951a/` |
| 本地签名 Release | `build/provider-credentials/discovery-credential-filter-build.log` 成功；严格签名验证通过，93 项产物配置检查无失败。`discovery-final-configuration.log` |
| 签名动态目录及取钥 | `build/provider-credentials/20261026T151950Z/result.json` 通过；五家新模型动态目录和 6 次本地认证请求，无真实供应商请求。 |
| 凭据泄露扫描 | `build/provider-credentials/discovery-secret-scan.json` 通过；扫描临时 Codex 的 115 个持久文件和日志，未发现测试 Key。 |

签名验收使用独立测试钥匙串、临时 Codex 数据目录、假 Key 和本地 Responses 模拟服务。由签名应用自身解析五家模拟列表并生成动态目录，实际 Codex 0.154.0 加载未内置的模型 ID。覆盖上下文缺失、任意推理档位、远端指令排除、GUI 未启动时取钥、独立进程再次取钥、Key 缺失及钥匙串锁定。检查用户钥匙串搜索列表未改变。

额外扫描脚本及结果放在 `build/provider-credentials/verify_discovery_secret_scan.py` 和 `discovery-secret-scan.json`；扫描临时 Codex 的全部持久文件及日志，凭据只在测试钥匙串和必要的子进程 stdout/请求头中流转，不落入诊断文件。

早期失败保留，没有算作通过：

- `20261026T145305Z-5bd9434a`：Swift 6 不允许异步测试直接遍历 DirectoryEnumerator，已先转换为数组。
- `20261026T145537Z-be9755d6`：禁止重定向后 Foundation 的错误分类不同，现由请求代理记录拒绝状态并统一分类。
- `20261026T150001Z-b6c81025`：中文原生夹具在获取完成前选择模型，现等待获取完成后再操作。
- `build/provider-credentials/20261026T150124Z`：Foundation 将已存在临时路径规范化为 `/tmp`，隔离目录校验现兼容两种系统别名，并增加回归测试。
- `20261026T151422Z-4e2e53e0`：虽然各项交互完成，但验证期间新增凭据回显过滤，入口将结果标为输入变化、不可复用；最终另跑完整验证。
- `20261026T150736Z-fd8e3d01`：临时 Codex 配置 RPC 一次连接中断；单独复核与后续完整回归通过，没有添加盲目重试。

## 交付与限制

- [本地签名应用](../build/local-releases/20261026T152115Z-live-models/Veyra.app)
- [通用 ZIP](../build/local-releases/20261026T152115Z-live-models/Veyra-1.3.2-live-models-macos-universal.zip)
- [版本、架构及 SHA-256](../build/local-releases/20261026T152115Z-live-models/manifest.json)

交付副本的二进制 SHA-256 与签名动态目录验收记录一致，应用资源内无旧模型 JSON。版本仍为 1.3.2 (6)，本地开发身份签名，通用架构 arm64 + x86_64；没有公证或发布。

未使用用户真实 Key，五家真实列表和模型推理请求均未验收。所有生成式模型请求仅发送至本地模拟服务，不发起付费请求。unsigned 编译及位图不作为系统钥匙串访问证明；原生 Esc 使用窗口合成事件，不代表硬件键盘或 VoiceOver 人工验收。


## 代表截图

使用固定模拟数据，不含真实 Key 或账户模型列表。

- [中文首次配置](design/provider-model-discovery/settings-zh-light.png) · [英文首次配置](design/provider-model-discovery/settings-en-light.png)
- [已获取模型／深色](design/provider-model-discovery/settings-zh-dark.png) · [加载中](design/provider-model-discovery/settings-loading.png)
- [缓存回退](design/provider-model-discovery/settings-cached.png) · [认证失败](design/provider-model-discovery/settings-auth.png)
- [空列表](design/provider-model-discovery/settings-empty-models.png) · [原模型已消失](design/provider-model-discovery/settings-removed.png)
- [英文增强对比度](design/provider-model-discovery/settings-en-contrast.png) · [英文降低透明度](design/provider-model-discovery/settings-en-opaque.png)
