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

构建完成后可直接打开开发产物：

```sh
open 'build/Build/Products/Release/Veyra.app'
```

也可以打开 `Veyra.xcodeproj`，选择 `Veyra` scheme 后运行。默认构建使用本地 ad-hoc 签名，无需配置开发者团队；Release 同时包含 Apple Silicon 和 Intel 架构。App target 开启 Hardened Runtime，App Sandbox 保持关闭。

工程使用 Xcode 同步文件夹（蓝色目录），`Veyra` 和 `VeyraTests` 中新增或删除的文件会自动反映到工程。`Veyra` 默认属于应用 target，`VeyraTests` 默认属于测试 target。测试额外使用 Core 源码、`MonitorStore.swift` 和本地化资源，这些跨 target 引用由生成脚本维护；新增、删除或重命名 Core 源码后需要重新生成，更新测试成员规则。`Info.plist` 仅作为应用构建配置输入，不会重复复制到资源中。

修改工程配置或上述 target 成员规则时，更新 `scripts/generate_project.py` 并重新生成：

```sh
python3 scripts/generate_project.py
```

`Veyra.xcodeproj` 由该脚本完整生成。重新生成会覆盖直接在工程文件中保存的签名设置，因此应先生成工程，再在 Xcode 中完成当次发布所需的本机签名选择。不要把 `DEVELOPMENT_TEAM`、证书信息或公证凭据提交到仓库。

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
python3 scripts/generate_project.py
```

应用、工程和 scheme 均名为 Veyra。开发默认 Bundle ID 为 `local.codexmonitor.app`；正式分发应沿用上一版正式 App 的标识，详见[发布前的 Bundle ID 核对](release.zh-CN.md#33-核对-bundle-id)。不同标识可能使用不同的偏好设置。

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

# 在独立窗口中使用真实数据检查内容布局，不用于验收菜单栏材质
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --show-panel

# 使用固定示例数据检查真正的菜单栏弹窗
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --preview-menu multiple

# 只对测试实例强制外观；可选 light/dark/light-increased/dark-increased
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --preview-menu local-quota --preview-appearance dark --preview-reduce-transparency

# 自动检查顶部、中部、底部、快速滚动和同一弹窗动态收缩
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --preview-menu multiple --exercise-menu-to "$PWD/build/menu-check"

# 启动后点击菜单栏，导出真实菜单布局位图并打印窗口编号和尺寸
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' \
  --capture-menu-to "$PWD/build/menu.png"
```

布局位图不包含完整的 WindowServer 玻璃合成。最终验收需要打开真实菜单，在浅色、深色、减少透明度和增加对比度环境下检查顶部、中部、底部、快速滚动、回弹及窗口动态收缩。

固定场景包括 `loading`、`empty`、`single`、`long-title`、`multiple`、`quotas`、`error`、`expanded`、`unknown`、`edge-cases`、`local-quota`、`stale-quota`、`no-quota`、`cooldown`、`task-family`、`family-expanded`、`family-context`、`quota-ring-low`、`quota-ring-high` 和 `refreshing`。

套餐徽标场景为 `plan-prolite`、`plan-business`、`plan-enterprise`、`plan-unknown`，均包含溢出列表。
映射依据、未知值处理和验证范围见[套餐显示名称映射](plan-display-names.md)。

重置次数场景包括 `reset-credits`（多批次）、`reset-credits-expired`（已到期）、`reset-credits-unknown`（明细不足与未知有效期）、`reset-credits-zero`、`reset-credits-unavailable`、`reset-credits-only`（没有额度窗口）和 `reset-credits-overflow`（96 个批次，可配合 `--exercise-menu-to` 验证大屏滚动）。

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

`update-available` 菜单预览显示固定的新版本提示，可搭配 `--preview-appearance`、`--preview-reduce-transparency` 和 `--exercise-menu-to` 检查实际菜单与滚动。设置页渲染包含未检查、检查中、有新版、已是最新、失败及限流六种状态；使用 `--render-previews ... --preview-settings-only` 单独渲染。预览与诊断不执行 GitHub 更新请求，更新测试使用假网络、独立偏好设置与可控时钟。

新增的更新状态文件与 Core 源码一同加入独立 XCTest target；调整成员关系后运行工程生成脚本。
