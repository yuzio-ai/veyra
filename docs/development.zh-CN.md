# 开发与手动发布

本文所有命令都从仓库根目录执行。项目使用 Xcode 26、Swift 6 和 macOS 14 部署目标，不包含第三方 Swift 包或构建依赖。

## 构建与测试

```sh
./scripts/build.sh
./scripts/test.sh
```

测试脚本先运行 XCTest，再使用临时空数据库和假 Codex 子进程检查实际应用的诊断输出与断管处理，不读取真实账号或任务。需要独立构建目录时使用：

```sh
VEYRA_DERIVED_DATA_PATH=/tmp/veyra-tests ./scripts/test.sh
```

`test.sh` 在启动 xcodebuild 前先探测派生数据目录是否可写：探测失败会直接以非零状态退出并提示改用 `VEYRA_DERIVED_DATA_PATH`，而不是让 xcodebuild 在 workspace arena 阶段报出难懂的 `Unable to write to info file`。已存在且属主正确不代表可写，受限环境（例如文件沙箱中的自动化会话）即使目录归当前用户所有也可能拒绝写入。

受限环境还会让 Swift 宏插件失效：`ObservationMacros` 与 `SwiftMacros` 的宏实现需要 `swift-plugin-server`，该辅助进程在文件沙箱下无法正常工作，编译会报 `External macro implementation type ... could not be found` / `produced malformed response`。这与派生数据路径无关，`VEYRA_DERIVED_DATA_PATH` 不能解决；需要为构建进程放行，或改用不受限的构建环境。放行后验证结论与普通开发机一致。

### Codex 固定验证入口

在此仓库的 Codex 会话中使用完整绝对路径，不在外层追加 `cd`、环境赋值、管道或日志重定向：

```sh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test --only-testing VeyraTests/MonitorStoreTests
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test --only-testing VeyraTests/MonitorStoreTests/testSavingSettingsClearsCachesAndStartsQuotaForNewLocation --only-testing VeyraTests/CoreTests/testRPCHandshakeRepeatedReadsAndSidecarCleanup
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews menu
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py release-build
```

前缀规则只匹配这条入口命令本身。`cd repo && … 2>&1 | tail -10` 会变成由 `cd`、入口命令和 `tail` 组成的复合命令，后两段不在任何窄范围规则里，因此每次都要人工授权；放宽到能匹配这种复合写法就等于放行任意 shell。工作目录由会话或 `workdir` 指定，日志由入口写入本次的 `build/local-verification/<时间戳>-<随机 ID>/`，失败信息本身带有日志路径，不需要外层管道裁剪。`--only-testing` 可重复，多个选择器在同一次 `test` 中传给 `test.sh`。

`test` 复用 `test.sh`，串联 XCTest、隔离诊断、验证入口的离线回归和配置检查。`previews menu|settings` 默认生成中英文固定数据预览，可用 `--language en|zh` 限定语言；需要新的 Debug 产物时只构建，不隐式运行 XCTest。`release-build` 复用 `build.sh`，检查无签名通用 Release 产物与辅助功能读取工具的 Swift 6 编译。普通 `build.sh` 与 `test.sh` 仍保留原有签名行为；自动入口使用 `--unsigned`。

派生数据与互斥锁位于 `/private/tmp/veyra-local-verification/<仓库路径哈希>/`，避开 Documents 的测试运行器限制。每次实际执行都在 `build/local-verification/<UTC 时间与随机 ID>/` 保留独立日志和 `result.json`。并发调用直接失败，不视为通过。收到 SIGINT、SIGTERM 或执行超时时，入口先终止工作进程组并回收直接子进程，再释放互斥锁；中断结果记为失败，不保存本次成功缓存。清理期间重复终止信号不会跳过回收。固定入口不接受任意派生目录、Xcode 参数或可执行路径。

### 应用副本回收

`build.sh`、`test.sh` 在退出时撤销本次构建产物的 LaunchServices 登记。固定验证入口在成功、失败和复用证据时也撤销 Debug、Release 与键盘焦点测试应用的登记，保留固定路径的构建缓存和验收日志。`verify_release_app.sh` 退出时撤销导出副本和 Veyra 发布归档的登记；归档及 ZIP 文件保持原样，`/Applications` 和 `~/Applications` 中的安装版保留登记。清理登记失败会使命令失败，不会成为新的成功验证证据。

旧构建目录、验收解压副本和工作树测试缓存可用以下命令集中回收。第一条只列出计划，第二条实际执行并在 `build/app-cleanup/` 保存路径与操作报告：

```sh
/usr/bin/python3 -I -B scripts/cleanup_app_copies.py clean
/usr/bin/python3 -I -B scripts/cleanup_app_copies.py clean --apply
```

脚本只删除已识别为 Veyra 的可丢弃 `.app`，不删除所在目录、日志、ZIP 或 `.xcarchive` 归档。它会撤销失效登记和归档副本的登记；未知位置的实际应用保留。运行中的应用、含符号链接的路径和正在验证的缓存跳过；检测到 `xcodebuild` 时拒绝执行删除。清理与验证共用非阻塞锁，不会停止应用进程。运行中跳过的副本须退出后重试。需要在能读取用户 LaunchServices 数据库和进程表的环境中执行，不能以沙箱返回的空登记结果作为清理成功证据。

Xcode 或 Finder 再次打开归档仍可能重新登记其中的应用；发布验收会再次撤销登记，也可重跑上述回收命令。不要重置整个 LaunchServices 数据库。

### 验证证据与权限

源码、资源、工程、验证脚本、xcconfig、工具链、运行环境与构建产物均未变化时，入口复用相同范围的成功记录，并输出 `SKIP` 和原证据目录；使用 `--force` 可重跑。复用前同时校验原日志的内容哈希与结果文件，删除或损坏证据后会重新执行。失败、证据缺失、运行期间输入变化均不写入可复用记录。局部测试的成功不能替代完整测试。中间修改优先运行相关测试；最终运行一次完整 `test`。已有成功证据后，没有新修改或失败时不重复完整验证。

窄范围规则模板为 `scripts/codex-local-verification.rules`。先校验，再安装到本仓库 `.codex/rules/local-verification.rules`：

```sh
/usr/bin/python3 -I -B scripts/install_verification_rules.py --check
/usr/bin/python3 -I -B scripts/install_verification_rules.py
```

规则只持久放行此绝对路径入口的 `test`、`previews`、`release-build`。规则不会修改沙箱配置或通用命令权限。项目 `.codex/` 需受信任，安装后重启 Codex；静态匹配通过不能证明当前桌面会话已加载规则。仓库搬迁后需审查并更新模板中的绝对路径。规则信任脚本内容，不校验内容哈希；修改验证脚本或规则需审查。已存在的 `.codex/rules/local-verification.rules` 与模板不一致时安装器拒绝覆盖，需先人工比对再替换，否则旧规则会继续生效。

真实启动与辅助功能读取保留 `prompt` 规则：`verify_local.py launch --language zh|en` 只启动当前已验证的 Release 应用；`verify_local.py ax-read <PID>` 只读取该仓库验证目录下、Bundle ID 为 `ai.yuzio.veyra` 的应用。读取工具不提供点击或字段修改，快照留在本机忽略的 `build/`；macOS 辅助功能权限独立于 Codex 授权。两者不属于普通测试或固定数据预览。

测试脚本最后运行 `scripts/verify_configuration.py`，只读校验工程配置与打包中 XCTest 无法覆盖的不变量：App Sandbox 关闭、应用 target 开启 Hardened Runtime 且测试 target 关闭、自动签名（Apple Development）、Team 只经未入库的 `Local.xcconfig` 提供（工程文件不含 `DEVELOPMENT_TEAM`）、混合 Info.plist 卫生（手工 plist 只保留 Xcode 无法生成的 key）、`LSUIElement` 菜单栏模式、macOS 14 部署目标、Swift 6 严格并发、应用仍链接系统 `libsqlite3`，以及测试 target 的成员例外覆盖全部共享 Core 源码和本地化资源且无失效条目。传入 `--app` 时同时检查测试宿主二进制的架构。带 `--derived-data` 且存在 Release 构建时，额外检查发行二进制同时包含 arm64 与 x86_64，以及合并后 Info.plist 的完整键集；没有 Release 构建时这些检查显示为跳过。单独运行：

```sh
python3 scripts/verify_configuration.py
```

上面的独立命令只检查源码和工程配置。测试宿主与产物检查使用上方的 Codex 固定验证入口；手动传入 `--app` 时应采用本次构建日志中的实际路径。`test.sh` 优先使用 `VEYRA_DERIVED_DATA_PATH`；未指定且仓库位于 `~/Documents`、`~/Desktop` 或 `~/Downloads` 时，默认派生目录为 `~/Library/Developer/Xcode/DerivedData/Veyra`，其他位置默认为仓库的 `build/`。

脚本按普通文本读取 `project.pbxproj` 与 `Veyra/Info.plist`，不写入任何文件；版本号与 tag 一致性只在 HEAD 存在 `vX.Y.Z` 标签时比较。构建配置直接维护在 `project.pbxproj`，修改不变量时同步更新本脚本的期望值。

构建完成后可直接打开开发产物：

```sh
open 'build/Build/Products/Release/Veyra.app'
```

也可以打开 `Veyra.xcodeproj`，选择 `Veyra` scheme 后运行。默认构建使用自动签名，Team 由 `Local.xcconfig` 提供；Release 同时包含 Apple Silicon 和 Intel 架构。App target 开启 Hardened Runtime，App Sandbox 保持关闭。

工程使用 Xcode 同步文件夹（蓝色目录），`Veyra` 和 `VeyraTests` 中新增或删除的文件会自动反映到工程。`Veyra` 默认属于应用 target，`VeyraTests` 默认属于测试 target。测试额外使用 Core 源码、`MonitorStore.swift` 和本地化资源，这些跨 target 引用维护在 `project.pbxproj` 的 `membershipExceptions` 中；新增、删除或重命名 Core 源码后需手工更新该列表，`verify_configuration.py` 会报出遗漏或失效条目。`Info.plist` 采用混合管理：标准 key 和 `INFOPLIST_KEY_*` 可表达的 key 由 target build settings 生成，手工文件只保留 `CFBundleIconFile`、`NSHighResolutionCapable` 等无法生成的 key；它仅作为构建配置输入，不会复制到资源中。

工程配置与上述 target 成员规则直接维护在 `Veyra.xcodeproj/project.pbxproj`，手工编辑或通过 Xcode GUI 修改均可（版本号、显示名、分类在 General 标签页）。

本机签名身份只写入未入库的 `Local.xcconfig`（由 `Signing.xcconfig` 以 `#include?` 可选包含）。仓库默认为自动签名：克隆后需在该文件填入本机 Team 才能构建，缺失时 xcodebuild 会报签名错误。Team 变更只改 `Local.xcconfig`；在 Xcode Signing 面板更换 Team 会把 `DEVELOPMENT_TEAM` 写回 `project.pbxproj` 并覆盖 xcconfig 层。不要把 `DEVELOPMENT_TEAM`、证书信息或公证凭据提交到仓库。

## 使用 Xcode 手动发布

完整步骤见[手动发布操作手册](release.zh-CN.md)，包括维护者与 Codex 的分工和授权、版本准备、Xcode Archive、Direct Distribution、公证导出、产物验证、签名配置清理、源码标签和 GitHub Release 上传。

日常开发默认使用 Apple Development 自动签名，Team 只由未入库的 `Local.xcconfig` 提供。发布时在 Xcode 核对团队与签名身份，不通过 Signing 面板切换 Team。发布标签中的功能、资源与版本必须对应归档，Archive 后修改这些内容需要重新归档。

## 品牌素材

原始矢量素材位于 `assets/brand/veyra-icon.svg` 和 `assets/brand/veyra-logo.svg`。界面使用从 SVG 导出的透明标志和字标，应用图标为 `Veyra/AppIcon.icns`。导出只裁掉透明留白并调整尺寸，保留矢量路径和渐变；菜单栏和字标随系统深浅色显示，面板图标保留原始配色。Logo 中的文字使用 SVG 指定的本机字体，优先选择 Avenir Next。

修改 SVG 后重新生成素材和标准尺寸 macOS 图标：

```sh
swift scripts/prepare_brand.swift
swift scripts/make_icon.swift Veyra/Resources/VeyraMark.png build/Veyra.iconset
iconutil -c icns build/Veyra.iconset -o Veyra/AppIcon.icns
```

应用、工程和 scheme 均名为 Veyra。默认 Bundle ID 为 `ai.yuzio.veyra`，与正式分发标识一致，详见[发布前的 Bundle ID 核对](release.zh-CN.md#33-核对-bundle-id)。不同标识使用不同的偏好设置。

## 开发检查

当前验证范围、截图入口与历史记录的区别见[验证索引](validation.md)。`build/local-verification/<run>/` 中的图片只对应该次源码；复核界面时使用本次成功记录中的目录，不混用早期预览或设计图片。

```sh
# 一次真实只读联调；默认不联网，输出不含邮箱、凭据、标题或会话正文
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --diagnose

# 明确验证联网额度链路
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --diagnose --network

# 渲染任务家族、项目分组、用量与 API 费用明细、额度、重置次数、空记录和冷却场景
# 输出浅色、深色及高对比度 PNG 和 layouts.json，不启动 Codex
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --render-previews "$PWD/build/previews"

# 独立验证中英文界面，含设置页；语言与区域参数仅作用于本次进程
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --render-previews "$PWD/build/previews-en" -AppleLanguages '(en)' -AppleLocale en_US
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --render-previews "$PWD/build/previews-zh" -AppleLanguages '("zh-Hans")' -AppleLocale zh_CN
# 仅复查设置页时，在上述命令后追加 --preview-settings-only
# 使用临时目录和独立偏好设置验证原生输入、键盘、窗口关闭及无障碍标签
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --render-previews "$PWD/build/settings-checks" --exercise-settings-only

# 在独立窗口中使用真实数据检查内容布局，不用于验收菜单栏材质
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --show-panel

# 使用固定示例数据检查真正的菜单栏弹窗
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --preview-menu multiple

# 只对测试实例强制外观；可选 light/dark/light-increased/dark-increased
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --preview-menu quotas --preview-appearance dark --preview-reduce-transparency

# 自动检查滚动、动态收缩、Escape 和焦点恢复；固定入口负责创建键盘宿主
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews menu --native-only --language zh

# 启动后点击菜单栏，导出真实菜单布局位图并打印窗口编号和尺寸
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --capture-menu-to "$PWD/build/menu.png"
```

布局位图不包含完整的 WindowServer 玻璃合成。最终验收需要打开真实菜单，在浅色、深色、减少透明度和增加对比度环境下检查顶部、中部、底部、快速滚动、回弹及窗口动态收缩。

固定场景包括 `loading`、`empty`、`single`、`long-title`、`multiple`、`quotas`、`error`、`expanded`、`unknown`、`edge-cases`、`no-quota`、`cooldown`、`task-projects`、`task-family`、`family-expanded`、`family-context`、`token-breakdown`、`token-edges`、`api-costs`、`quota-ring-low`、`quota-ring-high` 和 `refreshing`，以及 `tasks-only`、`quota-only` 和 `no-sources` 能力场景。完整列表以 `AppArguments.MenuScenario` 为准。

额度预览不依赖模型或服务商配置；不同配置不再控制额度显示与轮询。

套餐徽标场景为 `plan-prolite`、`plan-business`、`plan-enterprise`、`plan-unknown`，均包含溢出列表。
映射依据、未知值处理和验证范围见[套餐显示名称映射](plan-display-names.md)。

重置次数场景包括 `reset-credits`（多批次）、`reset-credits-expired`（已到期）、`reset-credits-unknown`（明细不足与未知有效期）、`reset-credits-zero`、`reset-credits-unavailable`、`reset-credits-only`（没有额度窗口）和 `reset-credits-overflow`（96 个批次，可通过 `--preview-menu reset-credits-overflow` 手动检查滚动）。

`--render-previews` 渲染菜单及通用设置固定夹具，覆盖浅色、深色和增加对比度。`--preview-settings-only` 只渲染设置。场景定义以 `AppArguments.MenuScenario`、`PreviewSupport.SettingsScenario` 和输出的 `layouts.json` 为准。无效或已移除的场景与外观、重复的取值选项、冲突的主模式，以及缺少主模式的预览选项，均在启动界面前失败，不会回退到真实监控。

核心测试覆盖额度窗口、缓存、累计 token、日志增量读取、文件替换与截断、父子任务、状态合并、进程证据、只读 SQLite、RPC 初始化与断管重连，以及诊断输出的隐私边界。尺寸测试覆盖自然高度、溢出上限、窗口边距、展开与收起及多屏尺寸变化。任务家族的专项结果见[父子任务卡片验收](history/task-family-validation.md)。

## 能耗验证

能耗脚本使用临时的 1,000 条任务记录和模拟 Codex 可执行文件，预热后测量主进程 CPU 与包含已回收子进程的生命周期 CPU。报告中的 CPU 时间不能换算为瓦数、耗电量或续航。

```sh
python3 scripts/measure_energy.py \
  --app build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra \
  --scenario idle --output build/energy/idle.json

python3 scripts/measure_energy.py \
  --app build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra \
  --scenario active --output build/energy/active.json

python3 scripts/measure_energy.py \
  --app build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra \
  --scenario panel --output build/energy/panel.json
```

脚本为 Codex 创建临时数据目录，不继承真实数据目录或账号环境变量。预检和测量进程均通过 `-codexHome`、`-codexExecutable` 显式覆盖已保存的手动路径，不修改用户原有设置。测量进程使用 `--energy-benchmark`，关闭更新检查与全局快捷键。诊断预检必须确认应用支持此隔离模式；旧构建会明确失败，需先重新构建。

进程创建后立即注册清理。就绪等待与退出等待均有时限；测量进程忽略 SIGTERM 时会升级为 SIGKILL，并通过非阻塞 `wait4` 保留生命周期 CPU 统计。预检中断、启动失败、采样失败及脚本收到 SIGINT/SIGTERM 时也会回收子进程。测量进程提前退出会报错，不生成本次结果；测量秒数必须为正数。

离线回归 `python3 -I -B scripts/test_measure_energy.py` 由 `test.sh` 一同执行。除隔离与参数检查外，还使用真实子进程运行脚本主流程，覆盖正常完成（测量子进程忽略 SIGTERM）、编译超时、就绪超时、预检失败、启动失败、采样失败、提前退出、SIGINT、SIGTERM 和输出失败，并检查全部子进程已回收、临时夹具已清理。

`active` 和 `panel` 场景包含三个持有真实文件句柄的模拟运行任务，并持续追加用量。`panel` 使用相同内容的原生调试窗口，不能替代真实菜单的玻璃与交互验收。脚本会先用目标应用的诊断确认运行任务数；夹具位于忽略的 `build/` 临时目录，结束后清理。测试方法、实测结果和限制见[能耗优化验收记录](history/energy-validation.md)，结构化汇总见 [energy-measurements.json](history/energy-measurements.json)。


### 设置与菜单验证

`previews settings` 渲染中英文设置夹具并执行原生交互检查，覆盖路径输入、关闭与重开、快捷键录制、单页窗口和缩小窗口后的滚动。结果为 `settings-native-checks.json`。`previews menu` 另外验证六种固定外观下的真实弹窗滚动、动态收缩、开关和 Escape，结果保存在对应语言目录的 `native-*/menu-check.json`。

键盘宿主使用独立 Bundle ID 的临时副本。修改其 Info.plist 后，验证入口以 `codesign --sign -` 绑定独立的临时签名身份并执行严格校验；不使用证书或钥匙串，不改写被测应用。复制未签名构建但只修改 Bundle ID，会保留与被测应用相同的链接器签名标识和代码摘要，不能视作独立的签名身份。签名或校验失败时不启动原生检查，也不保存成功证据。

宿主在连续三个计时器回合保持前台后，才向该请求对应的预览 PID 交出激活权限并确认；确认后不再为同一请求调用激活，避免撤销已交出的权限。宿主恢复后可以没有 key window，因为它不接收键盘事件；被测菜单仍必须独立满足 active/key、后台打开、Escape 关闭和前台恢复断言。原生夹具日志保留带单调时钟时间的激活、失焦与菜单关闭事件，准备阶段遇到前台切换仍会明确失败。

`test` 覆盖配置变化不影响额度和轮询、登录及账户变化、路径变化、服务可用性变化、请求合并和服务端等待时间。隔离诊断验证已移除的命令快速失败、不输出 Key 且不启动界面。自动验证不访问真实账号或钥匙串。

状态栏优先展示 Codex 同组的最多两个额度窗口，按周期从短到长排列；五小时额度在左、周额度在右。悬浮文字和辅助功能标签包含各自周期与余量，失败时保留缓存及 `*` 标记。数字与弧线独立按各窗口余量配色，任务数外框为 1pt 动态灰色细线。

菜单预览中的 `quota-cooldown-checks.json` 和 `quota-cooldown-*.png` 使用生产面板与真实时钟，覆盖请求中、请求结束后仍在冷却、延长截止、卸载重开、到期恢复及清除截止；没有固定预览时间，也不发出真实请求。`status-items-*.png` 覆盖单圈、双圈混合颜色、缓存及系统高亮，并校验双圈增加 28pt 宽度、失败前后图像保持一致。

### 更新检查验证

`update-available` 菜单预览显示固定的新版本提示，可搭配 `--preview-appearance`、`--preview-reduce-transparency` 手动检查实际菜单与滚动；自动交互检查使用固定验证入口。设置页渲染包含未检查、检查中、有新版、已是最新、失败、限流及检查失败但仍有缓存新版七种更新状态，以及自动/手动路径、检测中、未找到、无效路径、无效草稿和长路径场景；使用 `--render-previews ... --preview-settings-only` 单独渲染。预览与诊断不执行 GitHub 更新请求，更新测试使用假网络、独立偏好设置与可控时钟。

预览的“当前版本”读取本次应用的 Bundle 版本，不固定为旧版本。“有新版”使用下一补丁版本的合成数据，仅验证提示与布局，不表示该版本已发布。额度重置时间采用固定参考时钟，以保持边界场景可重复；任务标题、进展和路径均为监控功能的固定示例。

新增的更新状态文件与 Core 源码一同加入独立 XCTest target；调整成员关系后更新 `project.pbxproj` 的成员例外，并运行 `scripts/verify_configuration.py` 核对。

`previews menu --native-only --language en` 可仅执行六种固定外观的原生弹窗检查。其缓存范围与完整预览分开，不能替代完整中英文布局证据。

GUI 夹具的许可、进程回执、隔离数据和布局先写入临时验证目录，避免 Documents 的访问检查阻塞启动；完成或失败后将证据归档到仓库的本次输出目录。布局预览与原生菜单夹具均通过 LaunchServices 启动独立的 Debug 应用实例，传入固定预览参数和隔离 `CODEX_HOME`，以支持布局夹具内的原生键盘检查。菜单键盘检查要求应用已激活、弹窗是 key window，且任务用量展开按钮已成为 first responder，再通过原生窗口发送合成 Escape 事件。仅本地 Codex 任务且无额度服务的场景也检查真实 key window 和 Escape 关闭。菜单专项先等待独立身份的固定宿主激活，再启动预览；宿主只向预览 PID 交出激活权限。结果同时记录 `appWasActive`、`windowWasKey`、`openedFromBackground`、`previousApplicationRestored`；缺少任一焦点证据不能算通过。这仍是合成事件证据，不代表硬件键盘或 VoiceOver 人工验收。

每次夹具启动都有独立许可和进程回执。超时或中断先撤销许可；迟到的应用实例会在初始化 AppKit 前退出。已运行的实例只有在 PID、进程组、可执行文件路径和本次启动标识全部匹配时才会回收。LaunchServices 启动器返回零不能证明应用检查通过，运行器还要求有效的 `layouts.json` 或 `menu-check.json`。这些检查不启动已安装应用，不扩大通用命令权限。

焦点交接必须先确认宿主位于前台，再发送 `focus-request`；请求之后不能再重复激活宿主，否则可能取消其刚交出的激活权。宿主仅负责交接，实际菜单仍需通过 active、key window、Escape 与前台恢复断言。宿主日志立即记录交接状态；测试期间切换其他应用仍可能中断检查，此类失败保留为失败，不能按成功缓存。修复与补验证据见[历史验证记录](history/validation-log-2026-10-31.md#2026-10-31-原生外观补验与焦点握手修复)。

指定预览外观时，菜单夹具直接设置 `NSPopover.appearance` 及其窗口外观，以覆盖弹窗默认的浅色内容外观。原生检查在截图前核对实际 `effectiveAppearance`；`menu-check.json` 的 `appearance` 记录包含请求、系统解析与实际外观，并核对对比度和降低透明度夹具开关。实际外观必须与系统解析结果一致且保持请求的浅深色归属。当前系统会将手动高对比度外观解析为普通 Aqua／DarkAqua，应用仍使用既有对比度绘制夹具；此检查不修改全局辅助显示设置。仅场景名称或交互通过不足以证明外观正确。
