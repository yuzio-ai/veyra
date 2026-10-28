# 五家供应商预置来源（历史）

以下记录对应此前内置目录版本。实时模型版本已移除这些资源和固定默认模型；当前行为见 [实时模型验证](provider-model-discovery-validation.md)。

核对日期：2026-10-26。目录版本：`2026-10-26.1`。仅预置普通 API，不包含 Coding Plan。

| 供应商 | 官方资料 | SHA-256 |
| --- | --- | --- |
| deepseek | [官方接入说明](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/) | `2f6b3d06ce37abf0a160c38419a2791087b29b3415f8d4cb453805210abcdc05` |
| kimi | [官方接入说明](https://platform.kimi.com/docs/guide/codex-kimi) | `d828c262fd4c9e6611377ad5a3ec52fa2b0b61bde346bcb4a59d20ff72f47381` |
| glm | [官方接入说明](https://docs.bigmodel.cn/cn/guide/develop/responses/introduction) | `96dfde1660ef6a747c32dc0571bb51216b309dbf05f1ddedd7a47b469cfa52fe` |
| minimax | [官方接入说明](https://platform.minimax.cn/docs/m-plan/codex) | `598f427e9dc3b1701a9799b596b96c460f7a55b53f9c993b44de001b8c8ed8d7` |
| mimo | [官方接入说明](https://mimo.mi.com/docs/en-US/tokenplan/integration/codex-configuration) | `f018bdab65b541b61893934b76624932e51c9459b89a11ed348c978144476be6` |

能力目录由官方示例中的能力字段整理。保留上下文窗口、输入模态、工具调用格式、推理档位等字段，不导入 `model_messages`、审批策略、代理协作规则或完整行为提示模板。`experimental_supported_tools` 固定为空列表，满足 Codex 0.154.0 目录解析要求。

Kimi 的 Codex 官方示例不提供目录；根据其 Codex 与推理强度说明配置 1M 上下文和 low/high/max 档位，使用 Codex 默认函数工具路径。MiMo 保留官方要求的 `use_responses_lite`。

目录随应用发布，运行时不下载；应用将其复制为版本化文件，防止覆盖撤销记录引用的目录。联网可用性和账户模型权限仍需真实 Key 验证。
