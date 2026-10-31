# 服务商菜单与额度展示验证

日期：2026-10-30。

## 调整

- 当前服务商的标签、Logo、名称和箭头以 6pt 间距紧凑排列，整体靠右。原生按钮只覆盖可见控件，不再覆盖中间的弹性空白；长名称截断，完整名称保留在悬停提示与辅助功能标签中。
- 原生下拉菜单以控件下沿外 4pt 为锚点，右边缘与控件对齐。检查实际视图到屏幕的坐标转换，避免翻转坐标导致弹出方向错误。
- 切换列表使用服务商品牌 Logo，保留模板图片与彩色图片各自的渲染方式；未知服务商使用首字母或通用图标。检查全部六个品牌的原生菜单图片尺寸与实际位图资源。
- 移除额度窗口与重置次数卡片底部的联网校准时间。保留额度重置时间、重置次数到期时间、刷新冷却与失败提示。

## 验证隔离

首次主工作区验证期间，并行任务修改了任务项目相关源码。中英文各 440 张预览和六种原生菜单检查实际执行完成，但固定入口将汇总结果判为输入变化，因此不作为可复用的成功证据。

后续使用 `build/verification-snapshots/provider-menu-quota-20261030T0515/` 中的独立源码快照。复制时逐项核对源码与配置内容；生产源码在快照中冻结，不随主工作区后续改动更新。首次快照测试遇到并行任务尚未同步的 CLI 父任务来源断言，随后仅复制该任务已修正的一行断言，未修改快照的生产代码。来源与文件摘要记录在快照的 `snapshot-manifest.json` 中。

完整测试已通过：351 项 XCTest、32 项 Python 回归、9 项隔离诊断和 5 项语言检查。

- 测试证据：`../build/verification-snapshots/provider-menu-quota-20261030T0515/build/local-verification/20261030T051742Z-2ee9df8e/`。
- 中文预览：`../build/verification-snapshots/provider-menu-quota-20261030T0515/build/local-verification/20261030T051830Z-31062762/`；440 张布局预览及六种原生菜单外观与交互检查通过，包含控件命中、长名称、菜单锚点及品牌资源检查。
- Release：`../build/verification-snapshots/provider-menu-quota-20261030T0515/build/local-verification/20261030T052131Z-cc0e53a7/`；双架构构建与配置检查通过。

## 本地测试版

- App：`../build/local-delivery/provider-menu-quota-layout-20261030T052131Z/Veyra.app`。
- ZIP：`../build/local-delivery/provider-menu-quota-layout-20261030T052131Z/Veyra-1.3.2-provider-menu-quota-local-test-universal.zip`。
- 版本 1.3.2（6），支持 `x86_64 arm64`；链接器临时签名，无 Developer ID 签名或公证。
- SHA-256：`02cfb5f0ae9573e3464995be5bb5bcb3acd23c87be502f1653c499df5b42efa1`。
- 交付 App 与 ZIP 解压内容的文件、执行权限及链接已和验证后的构建逐项核对。

该测试版使用上述冻结快照，包含复制时工作区已有的未提交改动；不自动追入主工作区后续改动。交付涉及的界面源码已与快照清单摘要核对一致。未替换已安装应用或启动真实账号会话。

原生菜单锚点检查验证控件命中与屏幕坐标；不等同于在真实账号菜单中手动点击验收。静态位图不证明系统合成材质效果。真实钥匙串验收仍需要稳定签名版本。
