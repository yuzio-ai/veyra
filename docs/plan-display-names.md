# 套餐显示名称映射

核对日期：2026-09-09。来源为本机官方客户端 ChatGPT 26.901.51231（8109）的
`Contents/Resources/app.asar` → `webview/assets/app-initial-cadb12d4a15e.js`。
其中账户名称格式化函数 `W7i` 使用明确映射表 `E9i`，未命中时将下划线和连字符拆成单词。
这些压缩符号和资源文件名只用于定位该版本，更新客户端后可能变化。

官方 [App Server 认证文档](https://learn.chatgpt.com/docs/app-server#authentication-modes)
说明 `account/read` 和 `account/updated` 提供套餐信息，但没有完整的公开名称映射表。
以下对应关系来自客户端实现，不是根据内部字符串猜测的产品名称。

## 已确认的 15 个映射

| 内部值 | 官方显示名称 | Veyra 徽标 |
| --- | --- | --- |
| `free`, `free_workspace`, `guest` | Free | FREE |
| `go` | Go | GO |
| `plus` | Plus | PLUS |
| `pro`, `prolite` | Pro | PRO |
| `team`, `self_serve_business_prolite`, `self_serve_business_usage_based` | Business | BUSINESS |
| `business`, `enterprise`, `enterprise_cbp_automation`, `enterprise_cbp_usage_based`, `ent26` | Enterprise | ENTERPRISE |

该版本的购买界面把 `prolite` 和 `pro` 分别细分为 Pro 5x 与 Pro 20x；账户徽标统一显示 PRO。
`business` 对应 Enterprise，`team` 对应 Business，不能仅按内部名称直接大写。

## 未明确映射的值

客户端主套餐枚举有 25 个值；相关分支还出现 `guest`、`enterprise_cbp_trial`、`unknown`，
合计观察到 28 个不同值。这只是该版本的观察范围，不是服务端可能值的完整契约。

以下 13 个值没有命中上述显示名称表，Veyra 保留可读兜底，不为其推断公开产品归属：

| 内部值 | Veyra 徽标 |
| --- | --- |
| `education` | EDUCATION |
| `edu_plus` | EDU PLUS |
| `edu_pro` | EDU PRO |
| `edu` | EDU |
| `deprecated_edu` | DEPRECATED EDU |
| `k12` | K12 |
| `deprecated_enterprise` | DEPRECATED ENTERPRISE |
| `enterprise_cbp_trial` | ENTERPRISE CBP TRIAL |
| `hc` | HC |
| `finserv` | FINSERV |
| `sci` | SCI |
| `quorum` | QUORUM |
| `unknown` | UNKNOWN |

## 实现边界与验证

- `AccountSnapshot.plan` 保留原始接口值，身份与账户匹配继续使用原值。
- `planDisplayName` 仅在显示时去除首尾空白并忽略大小写匹配。
- 缺失、null、空串和纯空白不显示徽标；`unknown` 显示 UNKNOWN。
- 新值按下划线、连字符和空白拆词，以单个空格连接并大写；只有分隔符的值保留原文。
- 徽标单行显示，长名称截断，悬停提示保留完整显示名称。
- `QuotaPolicyTests` 覆盖 28 个已观察值、未来未知值、空值、规范化和原始身份保留。

菜单预览场景为 `plan-prolite`、`plan-business`、`plan-enterprise`、`plan-unknown`。
各场景包含溢出任务列表，可搭配 `--exercise-menu-to` 检查滚动；`--render-previews` 会渲染
浅色、深色和两种增加对比度布局。真实菜单材质检查另需使用 `--preview-menu`，
搭配 `--preview-appearance` 和 `--preview-reduce-transparency`，参见开发文档。

后续更新映射时，应重新核对官方客户端的明确显示表，同时更新此文档和回归用例。

### 本次验证（2026-09-09）

- 独立临时构建目录：139 项 XCTest、8 项诊断检查和 5 项语言检查全部通过。
- 184 张布局预览通过尺寸检查，包括四种套餐场景的浅色、深色及增加对比度布局。
- 实际 MenuBarExtra 检查通过：Pro 浅色、Business 深色、Enterprise 浅色增加对比度、
  未知长名称深色增加对比度并减少透明度；覆盖顶部、中部、底部、快速滚动和同一弹窗动态收缩。
- 已查看实际菜单的布局位图，确认名称映射、长名称截断和刷新控件位置。
  布局位图不包含完整的系统玻璃合成；另行调用系统窗口截图失败（`could not create image from window`），
  因此真实玻璃材质的屏幕合成截图验收仍未完成。
