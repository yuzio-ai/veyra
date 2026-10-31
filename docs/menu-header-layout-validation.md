# 菜单顶部布局与本地 App 交付

> 历史快照：服务商管理、取钥命令及按服务商屏蔽额度的行为已移除。下文仅记录当时的实现与证据。当前行为见[使用指南](user-guide.zh-CN.md)，移除范围与验收见[清理验证](provider-removal-validation.md)。

日期：2026-10-30。

## 改动

- 顶部第一行保留 Logo 和名称，设置与退出按钮移到右侧；电源按钮继续退出 Veyra。
- 第二行左侧显示电脑图标、读取状态点和“本机活动”，右侧显示“当前服务商”及供应商下拉。
- 下拉按钮仅覆盖右侧服务商区域。长名称截断，完整名称与“新会话配置”的含义保留在悬停提示中；辅助功能标签使用完整名称。
- 供应商错误、成功和配置覆盖提示保留为整行内容，不挤入下拉区域。
- 移除底部常驻说明及操作区；可用更新提醒继续保留。
- 任务与额度刷新统一为单箭头图标，沿用相同的尺寸、按钮样式与加载反馈；两项操作、额度冷却及失败退避保持独立。

## 验证

固定入口均完成实际执行：

```sh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews menu --language both
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py release-build
```

- 332 项 XCTest、32 项 Python 回归及 9 项隔离诊断通过。
- 中英文各 440 张布局预览通过，覆盖长名称、忙碌、错误、成功、配置覆盖等供应商状态。
- 原生控件检查验证右侧按钮两端的点击命中、左侧本机活动取样点不触发供应商菜单，以及完整辅助功能名称和提示。
- 六种原生弹窗外观检查通过，覆盖明暗、高对比度、减少透明度、滚动、菜单收缩及键盘关闭。
- 单任务固定场景高度 526pt，第三方供应商固定场景高度 262pt；移除底部操作后没有留下空白操作区。
- Release 构建和配置检查通过，已核对 `x86_64 arm64` 双架构、版本 1.3.2、构建号 6。

证据目录：

- 测试：`build/local-verification/20261030T030707Z-8be7bae9/`
- 预览：`build/local-verification/20261030T030821Z-0604a4d1/`
- Release：`build/local-verification/20261030T031425Z-241d28e0/`

## 本地交付

- App：`build/local-delivery/menu-header-layout/Veyra.app`
- 压缩包：`build/local-delivery/menu-header-layout/Veyra-1.3.2-local-release-universal.zip`
- SHA-256：`74d9248dd8fb5ef47129a474eb0d270c8d2f60832ef43be2d26fa050d0ff6ab9`
- 交付 App 的所有文件与链接均已和验证后的 Release 构建逐项核对。

这是使用固定入口生成的本地测试构建，仅有链接器临时签名，没有 Developer ID 签名或公证。未替换已安装应用，未连接真实账号验收；真实钥匙串功能仍需稳定签名版本验收。原生弹窗检查和布局位图不等同于完整 VoiceOver 或系统合成材质验收。
