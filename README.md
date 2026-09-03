# Veyra

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/veyra-logo-preview-dark.png">
  <img src="assets/brand/veyra-logo-preview.png" alt="Veyra" width="360">
</picture>

使用 Swift 6 和 SwiftUI 编写的原生 macOS 菜单栏应用。顶部显示当前 Codex 账号的剩余额度与本机运行任务数，点击查看额度窗口、重置时间、任务模型、运行时长和累计 token 明细。

## 运行

需要 macOS 14 或更新版本，并已安装、登录 Codex 桌面端或 CLI。应用依赖本机的 `codex` 可执行文件，不需要填写 API Key。

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

- **额度**：通过独立的 `codex app-server --stdio` 子进程读取 `account/read` 和 `account/rateLimits/read`。主额度可能是周、5 小时或其他窗口，窗口名称与百分比由实际响应决定。其他模型的独立额度窗口也会展示。剩余比例为 `100 − usedPercent`，不能换算成剩余 token 数。[Codex App Server 文档](https://developers.openai.com/codex/app-server)
- **运行任务**：只读访问 `state_*.sqlite`、`thread_history_*.sqlite` 和会话 JSONL；结合 `lsof` 获取的 Codex 任务锁／会话文件持有情况确认进程。未结束的轮次且有对应进程才计入运行数；不能确认的记录放入“状态待确认”。独立 App Server 的内存任务列表不用于判断桌面端或 CLI 的运行状态。
- **状态合并**：同一轮次的结束状态优先于开始状态，避免数据库秒级时间与日志毫秒级时间造成误判。不同轮次或缺少轮次 ID，且时间不足以可靠排序时显示“状态待确认”，不计入运行数，也不推测开始时间。
- **累计 token**：优先采用会话最新 `total_token_usage` 快照，缺少快照时使用数据库累计总量。输入包含缓存输入，输出包含推理输出，不重复相加。累计是该任务记录的总量，包含已完成轮次；子任务各自展示、各自计数，不再叠加到父任务。
- **刷新**：任务每 5 秒、额度每 60 秒更新。额度查询失败保留上次结果并显示更新时间，菜单栏百分比后的 `*` 表示上次数据；账号凭据发生变化时清除旧额度缓存。重置时间到了以后仍等待真实额度响应，不自行推算为 100%。

应用不创建、恢复或控制任务，不触发模型请求。账户认证和凭据刷新由 Codex 自身管理，应用不复制或存储登录凭证。应用只在自己的 UserDefaults 中保存两个可选路径设置；监控数据保存在内存，退出后清除。关闭 App Sandbox 是为了读取本机数据和进程。

额度错误在界面和诊断中统一显示固定的安全提示，舍弃后端原始错误文本和附加数据。诊断 JSON 保留 `quotaError` 提示，并通过 `quotaErrorCode` 返回稳定分类（如 `disconnected`、`timeout`、`rpc_failed`）；成功时两者均为 `null`。未知系统错误统一归为 `unknown`，不会导出其原始描述。

## 兼容性与限制

已在 macOS 26.5.2、Codex CLI 0.152.0、Swift 6.3.3 上验证，部署目标为 macOS 14。最低系统版本已编译检查，未在 macOS 14 真机验证。

额度接口沿用当前 Codex 登录。API Key 等不提供 ChatGPT 订阅额度的认证方式显示明确提示。本机任务列表对应所选 Codex 数据目录，不是跨设备的账号任务列表；不包含云端、其他设备、今日汇总或内部自动审批／维护线程。

Codex 本地数据库与会话格式属于实现细节，升级后可能发生变化。读取器支持现有分页存储和旧 JSONL 格式，对已知列做兼容检查；不兼容时显示错误，不创建数据库或执行迁移。默认查找数据目录根部的最新编号数据库，再查找其 `sqlite` 子目录。自定义独立 `sqlite_home` 布局需要额外适配。

## 开发检查

```sh
# 一次真实只读联调，输出不含邮箱、凭据、标题或会话正文的 JSON，然后退出
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --diagnose

# 渲染加载、空状态、单任务、长标题、多任务、多额度、错误、展开、待确认及边界数据场景
# 输出浅色／深色及高对比度的 40 张 PNG 和 layouts.json；不启动 Codex，图片使用不透明布局外观
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --render-previews "$PWD/build/previews"

# 在独立窗口中检查内容布局，使用真实数据；不用于验收菜单栏材质
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --show-panel

# 用固定示例数据检查真正的菜单栏弹窗，不读取 Codex；场景名见上方预览场景
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --preview-menu multiple

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
