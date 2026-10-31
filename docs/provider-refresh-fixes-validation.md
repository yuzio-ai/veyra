# 供应商切换与刷新行为修复验证

日期：2026-10-30。

后续页头读取失败重试与干净草稿状态保留修复见 [页头修复验证](header-retry-state-validation.md)。本页保留该阶段原始证据。

## 修复

1. **自定义 OpenAI 网关**：全局配置中的 `openai_base_url` 纳入供应商身份判断。即使 `model_provider` 缺省或仍为 `openai`，也隐藏官方额度并停止请求；路线变更清空旧额度和重置次数，丢弃切换前返回的额度数据。
2. **账号额度限流**：供应商往返切换保留原有最短间隔、失败退避及 Retry-After。尚未返回的账号请求继续合并；过期供应商响应只更新同一数据目录下的限流状态，不发布旧额度。等待到期后恢复自动获取。
3. **页头同步**：监控层检测配置值或文件版本变化后，异步通知供应商配置库重读。供应商 ID、OpenAI 网关覆盖和同一 ID 下的名称修改均可同步。忙碌时只保留最新重载请求；重载保留未保存草稿与显式操作的失败提示。

配置未变化的任务轮询不会重复调用供应商配置接口。配置重载与任务读取分开，仍保持只读，不写 Codex 配置。

## 回归

新增 9 项正式回归，总计 341 项 XCTest，通过：

- 缺省/显式 OpenAI provider 下的接口覆盖，包括显式空地址，以及注释和局部 profile 不改变全局路线。
- 网关切换隐藏额度、禁止继续请求、丢弃进行中的旧响应，以及移除覆盖后恢复官方路线。
- 供应商往返保留已返回的 Retry-After；进行中的请求只执行一次，迟到的限流响应仍有效，到期后恢复自动请求。
- 额度请求进行中及冷却期间，本地任务刷新均独立完成。
- 外部切换后页头同步，供应商改名、自定义网关与官方路线恢复同步；普通任务轮询不重复读取配置接口。
- 忙碌时排队处理最新配置，不覆盖草稿，不清除显式操作失败提示，不写 Codex 配置。

32 项 Python 回归、9 项隔离诊断、六种原生菜单外观与交互检查通过。Release 构建及配置检查通过，已核对 `x86_64 arm64` 双架构。

## 证据

```sh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews menu --native-only --language zh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py release-build
```

- 修复前复现：`build/local-verification/20261030T032614Z-21f83984/`。
- 最终全量测试：`build/local-verification/20261030T035726Z-5b11bd20/`。
- 原生菜单：`build/local-verification/20261030T035841Z-ceed80ad/`。
- Release：`build/local-verification/20261030T040041Z-f8a5c0e4/`。

## 交付

- App：`build/local-delivery/provider-refresh-fixes/Veyra.app`。
- ZIP：`build/local-delivery/provider-refresh-fixes/Veyra-1.3.2-provider-refresh-fixes-local-universal.zip`。
- 版本 1.3.2，构建号 6；约 4.1 MB。
- SHA-256：`c177e2a6beab8752a04a56e5846797c975015397b8aaa23bc5f9ce815efe1811`。
- App 全部文件与链接已和通过验证的 Release 产物逐项核对，ZIP 完整性检查通过。

本轮沿用前一轮的顶部和状态栏布局，未重复生成整套静态预览。本地测试构建仅有临时签名；没有替换已安装应用，没有查询真实账号额度，真实钥匙串仍需稳定签名版本验收。
