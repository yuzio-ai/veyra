# 供应商能力默认值补充验证

> 历史验证快照：以下行为和证据对应记录日期的源码。当前操作以[使用指南](user-guide.zh-CN.md#codex-供应商)为准；后续修改需重新验证，不能将本记录作为当前源码已通过的证明。

2026-10-26 实施，2026-10-27 完成验证。在实时模型获取版本上补充自动参数采用与来源显示。未修改真实配置，未提交、推送、公证或发布。

## 行为

- 未手动覆盖时，启用采用所选模型返回的上下文窗口及明确声明的默认推理档位，写入受控配置字段。
- 手动覆盖优先于供应商值；供应商未提供的字段跟随 Codex 默认值。仅返回可选档位、未声明默认档位时，不挑选第一档或最强档。
- 参数必须属于当前选中模型，不能使用其他模型的上下文或默认推理档位。
- 设置展示有效值、来自供应商／手动覆盖的来源，以及供应商声明的可选推理档位。高级选项留空表示自动采用供应商值。
- 刷新只更新模型缓存与设置显示，下次启用才更新 Codex。现有配置、撤销、Key 与模型选择保持原有保护。

## 验证

- 完整测试：327 项 XCTest 无失败，隔离诊断、脚本及 80 项工程配置检查通过。`build/local-verification/20261026T155022Z-2b9d21ed/`。
- 新增回归：自动采用默认推理档位和上下文；刷新改变默认值但不写入 Codex；下次启用采用新值；手动覆盖优先；只有档位列表不推断默认值；不同模型的元数据不能混用。
- 签名动态目录与独立测试钥匙串验收通过：`build/provider-credentials/20261026T155240Z/result.json`。实际 Codex 0.154.0，六次请求仅发送到本地模拟服务，无真实供应商请求。
- 签名构建：`build/provider-credentials/provider-capabilities-signed-build.log`；产物配置日志：`provider-capabilities-configuration.log`。
- 中英文各 404 张布局、原生设置交互和六种外观菜单检查通过：`build/local-verification/20261026T155237Z-3d6f3313/`。
- 最终 unsigned Release、产物配置与辅助读取工具构建通过：`build/local-verification/20261026T155935Z-5eebbe10/`。

早期 `20261026T154605Z-11244b69` 中，既有临时 Codex RPC 集成用例出现一次连接中断，新增能力用例通过；签名构建结束后串行复核完整测试通过。未增加自动重试，没有把失败记录算作通过。

## 交付

- [本地签名应用](../build/local-releases/20261026T155438Z-provider-values/Veyra.app)
- [通用 ZIP](../build/local-releases/20261026T155438Z-provider-values/Veyra-1.3.2-provider-values-macos-universal.zip)
- [版本及 SHA-256](../build/local-releases/20261026T155438Z-provider-values/manifest.json)
- [中文参数来源](design/provider-capabilities/provider-values-zh-light.png) · [深色](design/provider-capabilities/provider-values-zh-dark.png) · [英文](design/provider-capabilities/provider-values-en-light.png)
- [中文缺失参数回退](design/provider-capabilities/missing-values-zh-light.png) · [英文缺失参数回退](design/provider-capabilities/missing-values-en-dark.png)

截图为固定模拟数据，不代表真实账户模型列表。交付副本与签名验收的可执行文件哈希一致。

真实供应商 API 仍未使用用户 Key 验证，不发起付费模型请求。原生位图和合成 Esc 不代表 VoiceOver 或硬件键盘人工验收。
