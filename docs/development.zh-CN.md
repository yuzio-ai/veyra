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

日常开发使用默认 ad-hoc 配置。发布时在本机 Xcode 选择团队与签名身份，导出通过公证的 App 后恢复仓库默认配置；清理工程不会影响已导出的 App。发布标签中的功能、资源与版本必须对应归档，Archive 后修改这些内容需要重新归档。

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
  --preview-menu local-quota --preview-appearance dark --preview-reduce-transparency

# 自动检查顶部、中部、底部、快速滚动和同一弹窗动态收缩
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --preview-menu multiple --show-menu --exercise-menu-to "$PWD/build/menu-check"

# 启动后点击菜单栏，导出真实菜单布局位图并打印窗口编号和尺寸
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --capture-menu-to "$PWD/build/menu.png"
```

布局位图不包含完整的 WindowServer 玻璃合成。最终验收需要打开真实菜单，在浅色、深色、减少透明度和增加对比度环境下检查顶部、中部、底部、快速滚动、回弹及窗口动态收缩。

固定场景包括 `loading`、`empty`、`single`、`long-title`、`multiple`、`quotas`、`error`、`expanded`、`unknown`、`edge-cases`、`local-quota`、`stale-quota`、`no-quota`、`cooldown`、`custom-model`、`task-family`、`family-expanded`、`family-context`、`quota-ring-low`、`quota-ring-high` 和 `refreshing`。

`stale-quota` 使用记录时间早于预览参考时间 10 分钟的本地快照，用于检查旧记录时间的显示。

`custom-model` 使用自定义 provider，额度区域改为固定提示卡片，用于确认此时不展示 ChatGPT 额度与重置次数的本地值。

套餐徽标场景为 `plan-prolite`、`plan-business`、`plan-enterprise`、`plan-unknown`，均包含溢出列表。
映射依据、未知值处理和验证范围见[套餐显示名称映射](plan-display-names.md)。

重置次数场景包括 `reset-credits`（多批次）、`reset-credits-expired`（已到期）、`reset-credits-unknown`（明细不足与未知有效期）、`reset-credits-zero`、`reset-credits-unavailable`、`reset-credits-only`（没有额度窗口）和 `reset-credits-overflow`（96 个批次，可配合 `--exercise-menu-to` 验证大屏滚动）。

以上固定场景共 33 个；菜单场景 33 个、设置夹具 14 个，合计 47 个固定夹具，`--render-previews` 按浅色、深色和两种增加对比度各渲染一次，共 188 张布局位图。新增场景后需要同步本节和 `PreviewSupport.Scenario`。

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

`active` 和 `panel` 场景包含三个持有真实文件句柄的模拟运行任务，并持续追加用量。`panel` 使用相同内容的原生调试窗口，不能替代真实菜单的玻璃与交互验收。脚本会先用目标应用的诊断确认运行任务数；夹具位于忽略的 `build/` 临时目录，结束后清理。测试方法、实测结果和限制见[能耗优化验收记录](energy-validation.md)，结构化汇总见 [energy-measurements.json](energy-measurements.json)。


### 更新检查验证

`update-available` 菜单预览显示固定的新版本提示，可搭配 `--preview-appearance`、`--preview-reduce-transparency` 和 `--exercise-menu-to` 检查实际菜单与滚动。设置页渲染包含未检查、检查中、有新版、已是最新、失败、限流及检查失败但仍有缓存新版七种更新状态，以及自动/手动路径、检测中、未找到、无效路径、无效草稿和长路径场景；使用 `--render-previews ... --preview-settings-only` 单独渲染。预览与诊断不执行 GitHub 更新请求，更新测试使用假网络、独立偏好设置与可控时钟。

新增的更新状态文件与 Core 源码一同加入独立 XCTest target；调整成员关系后更新 `project.pbxproj` 的成员例外，并运行 `scripts/verify_configuration.py` 核对。
