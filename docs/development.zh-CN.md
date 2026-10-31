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

在此仓库的 Codex 会话中使用完整绝对路径，不在外层追加环境赋值或日志重定向：

```sh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test --only-testing VeyraTests/MonitorStoreTests
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews menu
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py release-build
```

`test` 复用 `test.sh`，串联 XCTest、隔离诊断、验证入口的离线回归和配置检查。`previews menu|settings` 默认生成中英文固定数据预览，可用 `--language en|zh` 限定语言；需要新的 Debug 产物时只构建，不隐式运行 XCTest。`release-build` 复用 `build.sh`，检查无签名通用 Release 产物与辅助功能读取工具的 Swift 6 编译。普通 `build.sh` 与 `test.sh` 仍保留原有签名行为；自动入口使用 `--unsigned`。

派生数据与互斥锁位于 `/private/tmp/veyra-local-verification/<仓库路径哈希>/`，避开 Documents 的测试运行器限制。每次实际执行都在 `build/local-verification/<UTC 时间与随机 ID>/` 保留独立日志和 `result.json`。并发调用直接失败，不视为通过。收到 SIGINT、SIGTERM 或执行超时时，入口先终止工作进程组并回收直接子进程，再释放互斥锁；中断结果记为失败，不保存本次成功缓存。清理期间重复终止信号不会跳过回收。固定入口不接受任意派生目录、Xcode 参数或可执行路径。

源码、资源、工程、验证脚本、xcconfig、工具链、运行环境与构建产物均未变化时，入口复用相同范围的成功记录，并输出 `SKIP` 和原证据目录；使用 `--force` 可重跑。复用前同时校验原日志的内容哈希与结果文件，删除或损坏证据后会重新执行。失败、证据缺失、运行期间输入变化均不写入可复用记录。局部测试的成功不能替代完整测试。中间修改优先运行相关测试；最终运行一次完整 `test`。已有成功证据后，没有新修改或失败时不重复完整验证。

窄范围规则模板为 `scripts/codex-local-verification.rules`。先校验，再安装到本仓库 `.codex/rules/local-verification.rules`：

```sh
/usr/bin/python3 -I -B scripts/install_verification_rules.py --check
/usr/bin/python3 -I -B scripts/install_verification_rules.py
```

规则只持久放行此绝对路径入口的 `test`、`previews`、`release-build`。规则不会修改沙箱配置或通用命令权限。项目 `.codex/` 需受信任，安装后重启 Codex；静态匹配通过不能证明当前桌面会话已加载规则。仓库搬迁后需审查并更新模板中的绝对路径。规则信任脚本内容，不校验内容哈希；修改验证脚本或规则需审查。

真实启动与辅助功能读取保留 `prompt` 规则：`verify_local.py launch --language zh|en` 只启动当前已验证的 Release 应用；`verify_local.py ax-read <PID>` 只读取该仓库验证目录下、Bundle ID 为 `ai.yuzio.veyra` 的应用。读取工具不提供点击或字段修改，快照留在本机忽略的 `build/`；macOS 辅助功能权限独立于 Codex 授权。两者不属于普通测试或固定数据预览。

测试脚本最后运行 `scripts/verify_configuration.py`，只读校验工程配置与打包中 XCTest 无法覆盖的不变量：App Sandbox 关闭、应用 target 开启 Hardened Runtime 且测试 target 关闭、自动签名（Apple Development）、Team 只经未入库的 `Local.xcconfig` 提供（工程文件不含 `DEVELOPMENT_TEAM`）、混合 Info.plist 卫生（手工 plist 只保留 Xcode 无法生成的 key）、`LSUIElement` 菜单栏模式、macOS 14 部署目标、Swift 6 严格并发、应用仍链接系统 `libsqlite3`，以及测试 target 的成员例外覆盖全部共享 Core 源码和本地化资源且无失效条目。传入 `--app` 时同时检查测试宿主二进制的架构。带 `--derived-data` 且存在 Release 构建时，额外检查发行二进制同时包含 arm64 与 x86_64，以及合并后 Info.plist 的完整键集；没有 Release 构建时这些检查显示为跳过。单独运行：

```sh
python3 scripts/verify_configuration.py --app "$PWD/build/Build/Products/Debug/Veyra.app/Contents/MacOS/Veyra"
```

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

```sh
# 一次真实只读联调；默认不联网，输出不含邮箱、凭据、标题或会话正文
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --diagnose

# 明确验证联网额度链路
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --diagnose --network

# 渲染任务家族、额度、本地来源、过期、空记录、冷却、刷新和圆环边界场景
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

# 自动检查顶部、中部、底部、快速滚动和同一弹窗动态收缩
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --preview-menu multiple --show-menu --exercise-menu-to "$PWD/build/menu-check"

# 启动后点击菜单栏，导出真实菜单布局位图并打印窗口编号和尺寸
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --capture-menu-to "$PWD/build/menu.png"
```

布局位图不包含完整的 WindowServer 玻璃合成。最终验收需要打开真实菜单，在浅色、深色、减少透明度和增加对比度环境下检查顶部、中部、底部、快速滚动、回弹及窗口动态收缩。

固定场景包括 `loading`、`empty`、`single`、`long-title`、`multiple`、`quotas`、`error`、`expanded`、`unknown`、`edge-cases`、`no-quota`、`cooldown`、`custom-model`、`task-family`、`family-expanded`、`family-context`、`quota-ring-low`、`quota-ring-high` 和 `refreshing`。

`custom-model` 使用自定义 provider，用于确认此时隐藏 ChatGPT 额度与重置次数，并停止额度请求。

套餐徽标场景为 `plan-prolite`、`plan-business`、`plan-enterprise`、`plan-unknown`，均包含溢出列表。
映射依据、未知值处理和验证范围见[套餐显示名称映射](plan-display-names.md)。

重置次数场景包括 `reset-credits`（多批次）、`reset-credits-expired`（已到期）、`reset-credits-unknown`（明细不足与未知有效期）、`reset-credits-zero`、`reset-credits-unavailable`、`reset-credits-only`（没有额度窗口）和 `reset-credits-overflow`（96 个批次，可配合 `--exercise-menu-to` 验证大屏滚动）。

菜单场景共 33 个、通用设置夹具 14 个，各按浅色、深色和两种增加对比度渲染，共 188 张。另有供应商设置 27 个场景、供应商菜单 15 个场景，各按六种外观渲染，共 252 张。完整 `--render-previews` 每种语言生成 440 张，中英文合计 880 张。`--preview-settings-only` 省略前 33 个菜单场景；场景数量应以 `PreviewSupport` 和 `ModelProfilePreviews` 的枚举及列表为准。

核心测试覆盖额度窗口、缓存、累计 token、日志增量读取、文件替换与截断、父子任务、状态合并、进程证据、只读 SQLite、RPC 初始化与断管重连，以及诊断输出的隐私边界。尺寸测试覆盖自然高度、溢出上限、窗口边距、展开与收起及多屏尺寸变化。任务家族的专项结果见[父子任务卡片验收](task-family-validation.md)。

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

脚本为 Codex 与 dsh 分别创建临时数据目录，不继承真实数据目录或账号环境变量。预检和测量进程均通过 `-codexHome`、`-codexExecutable`、`-dshHome` 显式覆盖已保存的手动路径，不修改用户原有设置。测量进程使用 `--energy-benchmark`，关闭更新检查与全局快捷键，并使用固定供应商状态，避免访问真实供应商库或钥匙串。诊断预检必须确认应用支持此隔离模式；旧构建会明确失败，需先重新构建。

进程创建后立即注册清理。就绪等待与退出等待均有时限；测量进程忽略 SIGTERM 时会升级为 SIGKILL，并通过非阻塞 `wait4` 保留生命周期 CPU 统计。预检中断、启动失败、采样失败及脚本收到 SIGINT/SIGTERM 时也会回收子进程。测量进程提前退出会报错，不生成本次结果；测量秒数必须为正数。

离线回归 `python3 -I -B scripts/test_measure_energy.py` 由 `test.sh` 一同执行。除隔离与参数检查外，还使用真实子进程运行脚本主流程，覆盖正常完成（测量子进程忽略 SIGTERM）、编译超时、就绪超时、预检失败、启动失败、采样失败、提前退出、SIGINT、SIGTERM 和输出失败，并检查全部子进程已回收、临时夹具已清理。

`active` 和 `panel` 场景包含三个持有真实文件句柄的模拟运行任务，并持续追加用量。`panel` 使用相同内容的原生调试窗口，不能替代真实菜单的玻璃与交互验收。脚本会先用目标应用的诊断确认运行任务数；夹具位于忽略的 `build/` 临时目录，结束后清理。测试方法、实测结果和限制见[能耗优化验收记录](energy-validation.md)，结构化汇总见 [energy-measurements.json](energy-measurements.json)。


### 模型配置验证

新增 `CodexModelProfilesTests`、`CodexModelProfilesStoreTests` 与 `CodexModelConfigurationIntegrationTests`，分别验证配置补丁与恢复记录、编辑与菜单共享状态、真实 Codex 的隔离配置接口。集成测试只使用临时 `CODEX_HOME`，不读取账号或调用模型接口；未安装 Codex 时标记跳过。

统一入口的 `previews settings` 和 `previews menu` 都补充 `models-*` 固定夹具：普通、空列表、字段错误、接口不可用、长列表和成功提示，覆盖中英文、浅深色、高对比度与不透明回退。布局位图不证明原生菜单交互或系统辅助功能行为；快速入口另覆盖供应商长名称、忙碌、配置不可用和策略覆盖。实际菜单测试仍使用固定夹具入口分别记录。模型方案的新增 Core 文件和可观察状态均加入独立测试 target。

模型固定夹具另外执行原生文本输入、保存、无效地址校验、关闭拦截及取消/放弃检查，结果为 `model-profile-native-checks.json`。`previews menu` 再执行六种固定外观下的真实 `--preview-menu multiple` 弹窗，检查滚动、动态收缩、开关和 Esc 后自动退出，结果保存在对应语言目录的 `native-*/menu-check.json`。这些命令只使用固定夹具；真实数据启动与外部辅助功能读取仍保留单独的审批边界，规则文件没有扩大通用命令权限。

### 更新检查验证

`update-available` 菜单预览显示固定的新版本提示，可搭配 `--preview-appearance`、`--preview-reduce-transparency` 和 `--exercise-menu-to` 检查实际菜单与滚动。设置页渲染包含未检查、检查中、有新版、已是最新、失败、限流及检查失败但仍有缓存新版七种更新状态，以及自动/手动路径、检测中、未找到、无效路径、无效草稿和长路径场景；使用 `--render-previews ... --preview-settings-only` 单独渲染。预览与诊断不执行 GitHub 更新请求，更新测试使用假网络、独立偏好设置与可控时钟。

新增的更新状态文件与 Core 源码一同加入独立 XCTest target；调整成员关系后更新 `project.pbxproj` 的成员例外，并运行 `scripts/verify_configuration.py` 核对。

供应商入口使用 SwiftUI 排版与原生透明按钮，原生菜单图标为 16pt。固定夹具检查整行点击区域、完整辅助功能名称、菜单当前项、禁用状态与快捷切换。`previews menu --native-only --language en` 可仅执行六种固定外观的原生弹窗检查，其缓存范围与完整预览分开，不能替代完整中英文布局证据。此选项只复用现有固定夹具命令，不扩大真实启动或辅助功能读取权限。

布局预览与原生菜单夹具均通过 LaunchServices 启动独立的 Debug 应用实例，传入固定预览参数和隔离 `CODEX_HOME`，以支持布局夹具内的原生键盘检查。菜单键盘检查要求应用已激活、弹窗是 key window，且供应商按钮已成为 first responder，再通过原生窗口发送合成 Escape 事件。纯 dsh 场景也检查真实 key window 和 Escape 关闭。菜单专项先等待独立身份的固定宿主激活，再启动预览；宿主只向预览 PID 交出激活权限。结果同时记录 `appWasActive`、`windowWasKey`、`openedFromBackground`、`previousApplicationRestored`；缺少任一焦点证据不能算通过。这仍是合成事件证据，不代表硬件键盘或 VoiceOver 人工验收。

每次夹具启动都有独立许可和进程回执。超时或中断先撤销许可；迟到的应用实例会在初始化 AppKit 前退出。已运行的实例只有在 PID、进程组、可执行文件路径和本次启动标识全部匹配时才会回收。LaunchServices 启动器返回零不能证明应用检查通过，运行器还要求有效的 `layouts.json` 或 `menu-check.json`。这些检查不启动已安装应用，不扩大通用命令权限。


## 五家 API 预置与钥匙串

供应商设置使用统一侧栏，包含官方 OpenAI、固定五家预置和自定义连接；旧连接保留原有身份并在同一侧栏编辑。保存使用 `saveWorkspace()`，模型列表由用户点击刷新后通过 `refreshWorkspaceModels()` 获取，不打包模型目录或固定默认模型。新增共享 Core 文件仍需同步更新 `membershipExceptions`。历史预置目录记录见 [此前来源](provider-presets-sources.md)。

`verify_local.py test` 使用内存凭据实现，不接触登录钥匙串。`previews menu` 包括新版设置、原生 SecureField 输入与清空、保存不启用、启用、未保存修改保护和快捷菜单检查。正式交付还需 `verify_local.py release-build`。

真实钥匙串能力单独使用稳定签名构建验收：

```sh
./scripts/build.sh
/usr/bin/python3 -I -B scripts/verify_provider_credentials.py --app build/Build/Products/Release/Veyra.app
```

该检查创建独立测试钥匙串和临时 Codex 目录，使用固定假 Key，仅向本地 Responses 模拟服务发送请求。验收由五家模拟响应动态生成的目录、退出界面后的无界面取钥、独立进程再次取钥、锁定和缺失错误；检查用户钥匙串搜索列表未改变。签名应用的隔离模式负责解析响应并生成目录，使用接口未预置的新模型 ID。结果在 `build/provider-credentials/<UTC时间>/result.json`。unsigned 测试通过不代表签名钥匙串能力通过。

当前设置行为及验证边界见 [Provider Settings V2 验证](provider-settings-v2-validation.md)；此前自动获取模型和钥匙串行为分别见 [历史模型发现验证](provider-model-discovery-validation.md) 与 [历史钥匙串验证](provider-presets-keychain-validation.md)。这些记录描述各自快照，不能替代当前源码的验证。真实供应商调用需要用户主动操作，自动验收只使用本地模拟服务。

### 文件钥匙串兼容边界

当前凭据保存在本机文件钥匙串，访问依赖签名应用的 ACL；测试使用独立钥匙串文件。非交互查询使用 `kSecUseAuthenticationContext` 与 `LAContext.interactionNotAllowed`，不再重复设置已废弃的 `kSecUseAuthenticationUIFail`。但 `LAContext` 不替代文件钥匙串的全部交互控制：取钥辅助进程仍在创建 NSApplication 前调用 `SecKeychainSetUserInteractionAllowed(false)`，避免锁定或 ACL 拒绝时弹出系统对话框。

`SecKeychainOpen`、默认钥匙串与锁定状态查询、夹具钥匙串的创建/锁定/删除及 ACL 创建仍是有意保留的兼容接口。编译器会报告废弃警告，不隐藏这些警告。迁移到 Data Protection 钥匙串会改变存储位置和访问规则，不能通过替换常量完成；后续迁移需单独设计现有凭据兼容与签名访问验证，不自动搬运用户 Key。

依据为 Apple 的 [SecItem 头文件](https://github.com/apple-oss-distributions/security/blob/main/keychain/headers/SecItem.h)、[查询路由实现](https://github.com/apple-oss-distributions/security/blob/main/OSX/libsecurity_keychain/lib/SecItem.cpp)及[文件钥匙串交互控制](https://github.com/apple-oss-distributions/security/blob/main/OSX/libsecurity_keychain/lib/StorageManager.cpp)。修改非交互策略后，必须对稳定签名构建重新运行独立钥匙串验收，覆盖正常读取、锁定、缺失、ACL 拒绝、移动 App 与独立进程再次取钥；unsigned 测试不替代这些证据。

### 纯 dsh 体验验证

使用 `/usr/bin/python3 -I -B scripts/verify_local.py previews menu --dsh-only` 渲染中英文的纯 dsh、空闲、未确认、故障、无数据源、另一来源故障及设置能力说明。该模式跳过无关的供应商图库，保留六种原生菜单外观检查；原生检查还验证纯 dsh 下隐藏额度和供应商入口、任务数与 Escape 关闭。输出包含布局位图及 `menu-check.json`，不访问真实账号。它与完整预览使用独立证据，不能替代完整预览。
