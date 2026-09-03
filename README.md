# Veyra

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/veyra-logo-preview-dark.png">
  <img src="assets/brand/veyra-logo-preview.png" alt="Veyra" width="360">
</picture>

使用 Swift 6 和 SwiftUI 编写的原生 macOS 菜单栏应用。顶部显示 Codex 额度快照与本机运行任务数，点击查看额度窗口、重置时间、任务模型、运行时长和累计 token 明细。

## 运行

需要 macOS 14 或更新版本，并已安装、登录 Codex 桌面端或 CLI。本地监控只读取已有数据；手动联网校准需要本机的 `codex` 可执行文件，不需要填写 API Key。

构建完成后，打开：

```sh
open 'build/Build/Products/Release/Veyra.app'
```

应用只出现在屏幕顶部菜单栏，不显示 Dock 图标。也可以将生成的 `.app` 拖到自己的“应用程序”目录。菜单栏使用 Veyra 标志，并随系统背景自动调整深浅；面板和设置保留原始米灰色标志。弹窗为 360pt 紧凑面板：高度随实际内容自动伸缩，达到所在显示器的可用高度上限后，仅中间正文滚动，标题、刷新和底部操作始终固定。系统负责弹窗材质、圆角与阴影，滚动卡片使用语义填充；macOS 26 的固定操作按钮使用原生 Liquid Glass，旧系统使用原生 bordered 样式。外观跟随系统浅色／深色切换，并支持“减少透明度”和“增加对比度”。点击图标后，首先显示运行任务及累计、输入、输出 token；任务标题前不显示图标，点击累计用量展开缓存和推理明细。刷新保留仍存在任务的展开状态，不主动滚回顶部。向下滚动可查看全部额度窗口，底部齿轮打开设置，电源按钮退出应用。

设置中的路径留空时会自动发现 Codex：优先检查已安装桌面应用，再检查 PATH 和常见 CLI 安装位置。默认数据目录为 `CODEX_HOME`，未设置时使用 `~/.codex`；从 Finder 启动通常不会继承终端中的环境变量，自定义目录请在设置中指定。

卡片内以信息分组区分层次：任务左侧汇总耗时与输入／输出，右侧突出可展开的累计用量；额度将窗口名称和重置时间放在左侧、剩余比例右对齐。较长数值自动转为纵向排列，不压小文字。卡片仅使用语义填充和系统分隔色细边界，低额度同时在进度和百分比上使用风险色。

## 构建和测试

使用 Xcode 26 / Swift 6 工具链，无第三方 Swift 包或构建依赖。

```sh
./scripts/build.sh
./scripts/test.sh
```

测试脚本先运行 XCTest，再用临时空数据库和假 Codex 子进程检查实际应用的诊断输出与断管处理，不读取真实账号或任务。需要独立构建目录时，可使用 `VEYRA_DERIVED_DATA_PATH=/tmp/veyra-tests ./scripts/test.sh`。

也可以打开 `Veyra.xcodeproj`，选择 `Veyra` scheme 后运行。工程使用本地 ad-hoc 签名，无需配置开发者团队。Release 默认构建 Apple Silicon 和 Intel 通用应用；此交付用于个人本机使用，不含 Developer ID 签名或公证。

添加或移除 Swift 源文件后，可用以下脚本更新工程引用：

```sh
python3 scripts/generate_project.py
```

## 品牌素材

原始矢量素材为 `assets/brand/veyra-icon.svg` 和 `assets/brand/veyra-logo.svg`。界面使用从 SVG 导出的透明标志和字标，应用图标为 `Veyra/AppIcon.icns`。导出仅裁掉透明留白并调整尺寸，保留矢量路径和渐变；菜单栏和字标随系统深浅色显示，面板图标保留原始配色。Logo 中的文字使用 SVG 指定的本机字体（优先 Avenir Next）。

修改 SVG 后，在项目根目录重新生成素材和标准尺寸的 macOS 图标：

```sh
swift scripts/prepare_brand.swift
swift scripts/make_icon.swift Veyra/Resources/VeyraMark.png build/Veyra.iconset
iconutil -c icns build/Veyra.iconset -o Veyra/AppIcon.icns
python3 scripts/generate_project.py
```

应用、工程和 scheme 均名为 Veyra。Bundle ID 沿用 `local.codexmonitor.app`，以保留已有的路径设置。

## 数据口径

- **额度**：默认读取会话 JSONL 中的 `token_count.rate_limits`，按额度桶采用记录时间最新的完整快照。任务与额度共用日志游标；冷启动补读最近 20 个非内部会话（包含归档），每个最多尾读 256 KiB。本地记录没有账号 ID，界面明确标注“本地快照／账号归属未确认”，菜单栏用 `~` 标记；超过 5 分钟没有新记录或已跨重置时间时显示“等待 Codex 更新”，不推算为满额。不同桶各自显示记录时间，记录缺失不会冒充完整账号额度。
- **联网校准**：仅点击“联网校准”时启动独立 `codex app-server --stdio`，读取 `account/read` 和 `account/rateLimits/read`，完成后关闭子进程。结果整体显示为账号额度；更晚的本地记录出现后整体切回本地来源，不混合账号信息。启动、普通刷新、打开菜单和唤醒均不请求额度网络接口。手动请求最短间隔 60 秒，联网失败后分别冷却 5、15、30 分钟，不自动重试；服务端提供更长等待时间时遵守。配置或未登录错误可在修正后重新操作。[Codex App Server 文档](https://learn.chatgpt.com/docs/app-server#auth-endpoints)
- **运行任务**：只读访问 `state_*.sqlite`、`thread_history_*.sqlite` 和会话 JSONL；结合 `lsof` 获取的 Codex 任务锁／会话文件持有情况确认进程。未结束的轮次且有对应进程才计入运行数；不能确认的记录放入“状态待确认”。独立 App Server 的内存任务列表不用于判断桌面端或 CLI 的运行状态。
- **父子任务**：同一家族共用卡片，按分割线和缩进展示，子任务默认全部可见、明细独立展开。结束或归档的父任务仅保留归属标题，不计入运行数；运行与待确认任务可以同卡展示，整组都待确认时才移入折叠区。已结束的子任务不保留。
- **子任务信息**：缺少名称／标题时采用任务路径末段（下划线替换为空格），再回退到代理昵称或短 ID。默认显示当前轮次面向用户的最近进展，最多两行，悬停查看摘要；没有进展时显示最近工具操作类别。只读取带明确轮次 ID 的公开 commentary 和工具名称，不使用继承对话、分派密文、推理或工具输出。信息在现有日志扫描范围内尽力获取，不因缺失进展回扫整个日志；摘要最多保留 2,000 字符，只在内存中缓存，不导出到诊断。
- **状态合并**：同一轮次的结束状态优先于开始状态，避免数据库秒级时间与日志毫秒级时间造成误判。不同轮次或缺少轮次 ID，且时间不足以可靠排序时显示“状态待确认”，不计入运行数，也不推测开始时间。
- **累计 token**：优先采用会话最新 `total_token_usage` 快照，缺少快照时使用数据库累计总量。输入包含缓存输入，输出包含推理输出，不重复相加。累计是该任务记录的总量，包含已完成轮次；子任务各自展示、各自计数，不再叠加到父任务。
- **刷新**：菜单打开或有已确认运行任务时每 5 秒检查，收起且无已确认运行任务时每 30 秒检查。打开菜单、手动刷新和唤醒立即检查本地数据；休眠暂停调度。每次仍采集新的进程证据，SQLite 连接与结果按数据库版本缓存，无变化日志不重复打开。认证文件变化使联网校准结果失效，本地记录仍保持账号归属未确认。

应用不创建、恢复或控制任务，不触发模型请求。账户认证和凭据刷新由 Codex 自身管理，应用不复制或存储登录凭证。应用只在自己的 UserDefaults 中保存两个可选路径设置；监控数据保存在内存，退出后清除。关闭 App Sandbox 是为了读取本机数据和进程。

额度错误在界面和诊断中统一显示固定的安全提示，舍弃后端原始错误文本和附加数据，仅提取结构化的 HTTP 状态码与重试秒数。诊断 JSON 保留 `quotaError` 提示，并通过 `quotaErrorCode` 返回稳定分类（如 `disconnected`、`timeout`、`rpc_failed`、`rate_limited`）；成功时两者均为 `null`。未知系统错误统一归为 `unknown`，不会导出其原始描述。

## 兼容性与限制

已在 macOS 26.5.2、Codex CLI 0.152.0、Swift 6.3.3 上验证，部署目标为 macOS 14。最低系统版本已编译检查，未在 macOS 14 真机验证。

额度接口沿用当前 Codex 登录。API Key 等不提供 ChatGPT 订阅额度的认证方式显示明确提示。本机任务列表对应所选 Codex 数据目录，不是跨设备的账号任务列表；不包含云端、其他设备、今日汇总或内部自动审批／维护线程。

Codex 本地数据库与会话格式属于实现细节，升级后可能发生变化。读取器支持现有分页存储和旧 JSONL 格式，对已知列做兼容检查；不兼容时显示错误，不创建数据库或执行迁移。默认查找数据目录根部的最新编号数据库，再查找其 `sqlite` 子目录。自定义独立 `sqlite_home` 布局需要额外适配。

## 开发检查

```sh
# 一次真实只读联调，输出不含邮箱、凭据、标题或会话正文的 JSON，然后退出
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --diagnose

# 渲染任务家族、额度、本地来源、过期、空记录和冷却等 17 种场景
# 输出浅色／深色及高对比度的 68 张 PNG 和 layouts.json；不启动 Codex，图片使用不透明布局外观
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --render-previews "$PWD/build/previews"

# 在独立窗口中检查内容布局，使用真实数据；不用于验收菜单栏材质
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --show-panel

# 用固定示例数据检查真正的菜单栏弹窗，不读取 Codex；场景名见上方预览场景
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --preview-menu multiple

# 仅测试实例强制外观，不修改系统设置；可选 light/dark/light-increased/dark-increased
# --preview-reduce-transparency 使用与“减少透明度”相同的应用内不透明回退样式
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --preview-menu local-quota --preview-appearance dark --preview-reduce-transparency

# 60 秒内打开测试菜单，自动检查顶部／中部／底部、快速滚动与同一弹窗动态收缩
# 仅允许与 --preview-menu 配合使用，输出布局位图及 menu-check.json
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --preview-menu multiple --exercise-menu-to "$PWD/build/menu-check"

# 启动后 30 秒内点击菜单栏，导出真实菜单的布局位图并打印窗口编号／尺寸
# 可与 --preview-menu single 等场景组合；布局位图不包含完整 WindowServer 玻璃合成
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --capture-menu-to "$PWD/build/menu.png"

# 使用上一条命令打印的窗口编号捕获系统合成结果（可能需要屏幕录制权限）
# screencapture -x -l <窗口编号> "$PWD/build/menu-native.png"
```

核心测试覆盖额度窗口、缺失数据、登录／网络失败缓存、累计 token、增量／半行日志、文件替换／截断、子任务、完成／中断、进程证据、只读 SQLite，以及真实子进程上的 RPC 初始化、断管重连和超时。回归测试同时检查同秒结束／轮次歧义、安全错误分类、跨块模型读取和缺失字段的扫描缓存；缓存按实际读取字节数验证，不依赖耗时阈值。实际应用诊断测试覆盖默认 SIGPIPE 行为、后端错误与标准错误输出中的隐私标记，以及启动失败和协议错误。尺寸测试覆盖自然高度、溢出上限、窗口边距、展开／收起及多屏尺寸变化。

视觉验收应打开真实菜单，分别滚到顶部、中部和底部，并检查快速滚动／回弹期间标题和底栏不被覆盖。使用同一背景分别比较浅色、深色、减少透明度及增加对比度；不透明布局预览不能证明 Liquid Glass 的最终效果。菜单预览场景名为 `loading`、`empty`、`single`、`long-title`、`multiple`、`quotas`、`error`、`expanded`、`unknown`、`edge-cases`。边界场景包括长数值、缺失用量、子任务、不到 1% 的剩余额度和过期／缺失重置时间；固定单任务和多额度预览附带紧凑高度回归检查，运行时不使用这些预览高度预算。

界面使用 [SwiftUI MenuBarExtra 窗口样式](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window)。
固定操作控件使用 [Apple Liquid Glass API](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)，遵循 [Apple 关于固定玻璃操作层与滚动内容层的建议](https://developer.apple.com/forums/thread/791070)，不再额外叠加 `NSVisualEffectView` 或修改系统弹窗外观。


## 能耗验证

`--diagnose` 默认只读本地，输出缓存命中后的查询次数、日志字节数和打开次数。需要明确验证联网链路时使用 `--diagnose --network`。

```sh
python3 scripts/measure_energy.py --app build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra --scenario idle --output build/energy/idle.json
python3 scripts/measure_energy.py --app build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra --scenario active --output build/energy/active.json
python3 scripts/measure_energy.py --app build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra --scenario panel --output build/energy/panel.json
```

每次使用临时的 1,000 条任务记录和模拟 Codex 可执行文件，预热 10 秒后测量 5 分钟，不访问真实账号。`active` 和 `panel` 场景包含 3 个持有真实文件句柄的模拟运行任务并持续追加用量；`panel` 使用相同内容的原生调试窗口，不能代替真实菜单的玻璃与开关验收。报告区分主进程稳定期 CPU、唤醒次数和含已回收子进程的生命周期 CPU，不能将这些指标换算为瓦数或续航。

脚本先用目标应用的诊断验证运行任务数，再开始计时；进程 CPU 的 Mach 时间单位转换为秒。夹具位于忽略的 `build/` 临时目录内，结束后清理。测试记录见 [能耗优化验收](docs/energy-validation.md)。

新增预览场景：`local-quota`、`stale-quota`、`no-quota`、`cooldown`，用于核对本地来源、过期提醒、空记录和联网冷却。

任务家族预览：`task-family` 覆盖父子同卡、多级缩进、混合状态和长进展，`family-expanded` 同时展开父任务与子任务明细，`family-context` 覆盖父任务结束、待确认或缺失时的归属展示。
