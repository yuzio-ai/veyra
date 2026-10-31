# 页头重试与编辑状态保留验证

日期：2026-10-30。

## 修复

- 配置读取失败保留待处理请求，按 5、15、30、60 秒退避，后续间隔上限 60 秒。配置没有再次变化、菜单没有重新打开时也会恢复读取。
- 新配置会替换旧请求并取消旧等待；前台手动读取可立即尝试，失败后仍进入退避。取消过的等待不能再次发出请求。
- 供应商操作、模型发现或连接测试进行中时保留待处理请求，结束后继续重载，不打断用户发起的操作。
- 后台读取错误与用户操作反馈独立。恢复后清除读取错误，不清空仍有效的操作失败或成功提示。
- 后台重载不执行编辑器导航重置。干净草稿下仍保留“设为默认”、替换 Key、验证标记和操作状态；未保存草稿继续保留。保存数据确有变化时才更新干净草稿及基线。

## 回归

新增 8 项回归，349 项 XCTest 全部通过：

1. 干净草稿下保留错误、成功提示、设为默认及编辑选择；等待连接测试结束，不取消进行中的测试。
2. 连续读取失败按 5、15、30、60 秒退避；新配置替换等待，取消的等待不重复读取，恢复后重新从短间隔开始。
3. 重试到期时仍忙碌，则等待操作结束，不丢失请求。
4. 前台读取成功后取消旧重试，避免重复调用。
5. 前台读取失败也自动重试，恢复后清除该读取错误。
6. 退避期间的前台读取再次失败时，不立即连续重读。
7. 外部切换后短暂读取失败，不改文件、不重开菜单也会自动同步页头；保留已有操作反馈和选择，配置不变的普通任务刷新不重复读取配置。
8. 模型发现进行中时延后页头读取，发现结果仍被接收，之后同步当前服务商。

之前的供应商额度隐藏、Retry-After 保留、进行中请求合并与旧额度丢弃、独立刷新等回归继续通过。32 项 Python 回归、9 项隔离诊断、6 种原生菜单外观与交互检查，以及双架构 Release 构建通过。

## 证据

```sh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews menu --native-only --language zh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py release-build
```

- 修复前复现：`build/local-verification/20261030T040916Z-82939018/`。
- 全量回归：`build/local-verification/20261030T043348Z-e2825086/`。
- 原生菜单：`build/local-verification/20261030T043521Z-8b1df93d/`。
- Release：`build/local-verification/20261030T043804Z-21b9c527/`。

## 本地交付

- App：`build/local-delivery/header-retry-state-fixes/Veyra.app`。
- ZIP：`build/local-delivery/header-retry-state-fixes/Veyra-1.3.2-header-retry-state-fixes-local-universal.zip`。
- 版本 1.3.2，构建号 6；支持 `x86_64 arm64`，约 4.1 MB。
- SHA-256：`660caabeb660803e892025091cf277398155918cac45c24b076504222a671328`。
- 交付 App 的文件和链接已与验证后的 Release 逐项核对，ZIP 完整性检查通过。

读取失败与退避采用隔离数据及模拟时钟验证；未查询真实账号额度。交付为临时签名的本地测试构建，未替换已安装应用，真实钥匙串仍需稳定签名版本验收。本轮没有重复生成整套静态预览。

## 目录切换重试补充修复

日期：2026-10-30。

- 后台重载循环在每次读取前检查重试等待。旧目录读取返回后，不会提前消费新目录已进入退避的请求。
- 创建重试时保留已有计时器，不覆盖等待中的任务句柄，避免留下重复计时器。
- 新增两项回归：旧读取在等待期限前结束时，新目录只在第 5、20 秒读取；等待期限在旧读取期间到期时，旧读取结束后继续处理新目录请求。
- 两项回归同时验证旧目录结果被丢弃、恢复后清除读取错误、成功后没有遗留请求，以及整个过程不写入 Codex 配置。
- 修复前，新回归复现提前读取和重复计时器：`build/local-verification/20261030T050607Z-43fefa9b/`。
- 修复后，页头专项 24 项通过：`build/local-verification/20261030T050637Z-a7edec0c/`。
- 首轮 351 项全量通过：`build/local-verification/20261030T050746Z-1d90a6b9/`。之后工作区有其他并发修改进入，最终以以下当前代码验证为准。
- 当前代码全量 365 项 XCTest、32 项 Python、9 项隔离诊断与 5 项语言检查通过：`build/local-verification/20261030T052146Z-52a4c8ed/`。供应商切换、额度隐藏、旧响应丢弃、Retry-After 保留及独立刷新回归继续通过。
- 全量验证中同步补全了归档父任务夹具的 CLI 来源期望。数据库夹具明确记录 `source='cli'`，不应使用新字段的桌面端默认值；未修改该路径的生产逻辑。
- 更早的 `20261030T050703Z-8a8f42d8` 虽然用例通过，但输入在运行期间变化，不作为有效交付证据。

目录切换修复的最新本地交付：

- 双架构 Release 构建与配置验证：`build/local-verification/20261030T052239Z-12288118/`。
- App：`build/local-delivery/directory-retry-fix/Veyra.app`。
- ZIP：`build/local-delivery/directory-retry-fix/Veyra-1.3.2-directory-retry-fix-local-universal.zip`。
- 版本 1.3.2，构建号 6；`x86_64 arm64`；4,438,194 字节，临时签名的本地测试构建。
- SHA-256：`f4f2950143d9ba2349a6a59b359031f1e5575d77379f691ef6b345d13932b796`。
- 交付前再次核对全量测试与 Release 的源码、工具链指纹一致；导出 App 与验证后的 Release 文件及链接一致，ZIP 内容逐文件校验通过。没有使用等待期间的旧交付草稿。
- 未重复请求真实账号额度，也未覆盖已安装的 App。本次补充修复没有改动 UI；并发运行的预览记录未计作本轮有效验证证据。
