# 菜单键盘焦点与 Escape 验证

日期：2026-10-30（Asia/Shanghai）。

## 当前结论

本轮最终源码的完整回归、中英文各六种原生菜单外观与通用 Release 构建全部通过。此前的焦点失败已完成后续修复与复核，历史失败记录保留在下文。

## 产品修复

`MenuBarController.show()` 在原生弹窗显示后明确请求应用激活。仅调用 `makeKey()` 不能保证后台应用会接收键盘输入。弹窗使用当前 Space，并保留全屏辅助窗口行为；没有引入全局键盘监听或改变 Escape 的响应链。

`hide()` 通过协作激活先交还权限，再激活原来的前台应用。只有菜单拥有键盘焦点且 Veyra 仍是前台应用时才恢复；从菜单进入设置时仍保持设置焦点。

Apple 的 [activate()](https://developer.apple.com/documentation/appkit/nsapplication/activate()) 和 [yieldActivation(to:)](https://developer.apple.com/documentation/appkit/nsapplication/yieldactivation(to:)) 文档说明了激活请求和权限交还的关系。

## 自动夹具修复

原生菜单夹具此前依赖 LaunchServices 或前一组设置预览留下的激活状态。直接从后台调用打开方法，不能等同于真实鼠标/快捷键产生的系统激活授权。失败时已观测到弹窗可见、允许成为键盘窗口，但 `active=false`、`key=false`，前台仍为其他应用。将按钮设为 first responder 或重复普通激活请求都不足以建立这个前置条件。

现在由独立 Bundle ID 的固定测试宿主提供协作激活权限：

1. 先启动宿主，等待它已激活且窗口为 key，并写入带本次许可的就绪回执，再启动菜单预览。并行启动曾造成两者都未激活，已改为串行握手。
2. 打开菜单前，宿主取得前台并向指定预览 PID 交出激活权。此时预览必须仍在后台。
3. 调用真实 `MenuBarController` 打开菜单。必须确认应用已激活、弹窗是 key；Codex 场景额外聚焦原生供应商按钮，然后通过窗口分派 Escape。
4. 验证弹窗关闭且前台恢复到原宿主。纯 dsh 场景走相同流程，保留隐藏供应商/额度及任务数量断言。

宿主只交出激活权限，不替菜单调用激活、打开或关闭，不直接处理 Escape。每种样式要求 `appWasActive`、`windowWasKey`、`openedFromBackground` 和 `previousApplicationRestored` 全为 true。缺少任一证据不能记为通过。

## 隔离与回收

- 宿主复用验证后 Debug 程序的独立副本，具有单独 Bundle ID；原应用身份、菜单栏模式及已安装应用不变。
- 宿主入口在监控和更新初始化之前运行，要求有效的本次预览许可。只读取夹具目录中的许可、进程回执和激活握手。
- 菜单与宿主都由 LaunchServices 启动，分别记录 PID、进程组和令牌。超时或中断撤销许可；回收前核对身份，拒绝信号错误实例。
- 修复撤销许可后正常退出恰好发生在参数检查期间的竞态：只有确认进程已经退出才接受；存活但参数不同的进程仍拒绝回收。
- 未新增通用命令授权或修改沙箱设置。

## 最终证据

| 检查 | 结果与证据 |
| --- | --- |
| 完整回归 | 372 项 XCTest、33 项验证入口 Python 回归、11 项能耗回归、隔离诊断与配置检查通过：`build/local-verification/20261030T100036Z-7eb5a6e7/result.json` |
| 英文原生菜单 | 六种外观通过：`build/local-verification/20261030T095914Z-32630f60/result.json` |
| 中文原生菜单 | 六种外观通过：`build/local-verification/20261030T100127Z-ed6f7967/result.json` |
| Release | 未签名通用构建、配置检查及辅助功能读取器编译通过：`build/local-verification/20261030T100308Z-6aa3a58b/result.json` |

十二组样式共验证 24 条 Codex/纯 dsh 后台打开、真实激活与 key window、Escape 关闭、原应用恢复链路，并继续覆盖溢出滚动、窗口收缩与切换开关。退出后仅剩用户原先运行的本地应用，测试预览与焦点宿主均已回收。

复现命令：

```sh
/usr/bin/python3 -I -B scripts/verify_local.py test
/usr/bin/python3 -I -B scripts/verify_local.py previews menu --native-only --language en
/usr/bin/python3 -I -B scripts/verify_local.py previews menu --native-only --language zh
/usr/bin/python3 -I -B scripts/verify_local.py release-build
```

这些结果使用固定数据和真实 AppKit 窗口的合成事件。原生输入工具曾读取到独立预览界面，但后续键盘操作超时，不计作硬件输入证据。真人全屏 Space、系统玻璃合成和 VoiceOver 尚未验收；不查询真实账号或供应商服务。

## 历史失败

- 清理阶段两次在焦点前置条件失败：`20261030T092057Z-9378314e`、`20261030T092210Z-b74f3157`。
- 从明确后台状态复现可见但未激活的弹窗：`20261030T093110Z-9e74d96d` 的 `native-menu-dark-opaque.log`。
- 仅增加普通或旧式激活请求仍失败：`20261030T093249Z-db5d21cb`、`20261030T093557Z-fe3485a5`。
- 退出参数读取竞态：`20261030T095142Z-3008bd14`；并行启动竞态：`20261030T095702Z-628eb1a9`。均未计为最终通过。

## 本地交付

- App：`build/local-preview/keyboard-focus-fix/Veyra.app`
- ZIP：`build/local-preview/keyboard-focus-fix/Veyra.zip`
- 版本：1.3.2（6），arm64 与 x86_64。
- ZIP SHA-256：`a3ae4127fbf5f5acea5cc2bfd63e54dcc42d707e4214629c7e9669bbead1f1ca`。

App 文件、链接与验证后的 Release 完全一致，ZIP 完整性通过。交付保持原应用身份和菜单栏模式，为未签名本地预览版。
