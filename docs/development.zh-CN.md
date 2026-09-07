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

添加或移除 Swift 源文件后，重新生成工程引用：

```sh
python3 scripts/generate_project.py
```

`Veyra.xcodeproj` 由该脚本完整生成。重新生成会覆盖直接在工程文件中保存的签名设置，因此应先生成工程，再在 Xcode 中完成当次发布所需的本机签名选择。不要把 `DEVELOPMENT_TEAM`、证书信息或公证凭据提交到仓库。

## 使用 Xcode 手动发布

公开分发前需要有效的 Apple Developer Program 会员资格，以及安装在本机钥匙串中的 `Developer ID Application` 证书。仓库不保存证书、Apple Team、Apple ID 或公证凭据。

1. 运行 `python3 scripts/generate_project.py`，然后打开 `Veyra.xcodeproj`。
2. 在 Xcode 的 **Settings → Accounts** 登录 Apple 开发者账号。
3. 选择 Veyra target，在 **Signing & Capabilities** 中为本次 Archive 选择开发者团队和 Developer ID 签名。确认 Hardened Runtime 已启用、App Sandbox 保持关闭。
4. 选择适用于归档的 Mac 目标，然后执行 **Product → Archive**。
5. 在 Organizer 中选择归档，执行 **Distribute App → Direct Distribution**。让 Xcode 完成 Developer ID 签名、Apple 公证和导出。
6. 验证导出的应用：

   ```sh
   codesign --verify --deep --strict '/path/to/Veyra.app'
   spctl --assess --type execute --verbose=4 '/path/to/Veyra.app'
   xcrun stapler validate '/path/to/Veyra.app'
   ```

7. 使用 `ditto` 保留 macOS bundle 元数据并生成压缩包：

   ```sh
   ditto -c -k --sequesterRsrc --keepParent \
     '/path/to/Veyra.app' \
     'Veyra-v1.0.0-macos-universal.zip'
   ```

8. 在 GitHub 的 Releases 页面创建与版本对应的 tag，上传 ZIP 并手动发布。

发布前同步更新 `Veyra/Info.plist` 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`。Xcode 完成本机签名设置后，提交其他代码前检查 `git diff`，避免将个人 Team 设置带入版本控制。

## 品牌素材

原始矢量素材位于 `assets/brand/veyra-icon.svg` 和 `assets/brand/veyra-logo.svg`。界面使用从 SVG 导出的透明标志和字标，应用图标为 `Veyra/AppIcon.icns`。导出只裁掉透明留白并调整尺寸，保留矢量路径和渐变；菜单栏和字标随系统深浅色显示，面板图标保留原始配色。Logo 中的文字使用 SVG 指定的本机字体，优先选择 Avenir Next。

修改 SVG 后重新生成素材和标准尺寸 macOS 图标：

```sh
swift scripts/prepare_brand.swift
swift scripts/make_icon.swift Veyra/Resources/VeyraMark.png build/Veyra.iconset
iconutil -c icns build/Veyra.iconset -o Veyra/AppIcon.icns
python3 scripts/generate_project.py
```

应用、工程和 scheme 均名为 Veyra。Bundle ID 保持 `local.codexmonitor.app`，以保留已有的路径设置。

## 开发检查

```sh
# 一次真实只读联调；默认不联网，输出不含邮箱、凭据、标题或会话正文
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --diagnose

# 明确验证联网额度链路
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --diagnose --network

# 渲染任务家族、额度、本地来源、过期、空记录、冷却、刷新和圆环边界场景
# 输出浅色、深色及高对比度 PNG 和 layouts.json，不启动 Codex
'build/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra' --render-previews "$PWD/build/previews"

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
