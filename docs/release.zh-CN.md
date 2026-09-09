# Veyra 手动发布操作手册

适用于通过本机 Xcode 签名、公证，再通过 [GitHub Releases](https://github.com/yuzio-ai/veyra/releases) 分发 macOS 应用的流程。日常开发与提交保持无本机签名身份的配置；发布时临时选择开发者团队，导出后清理工程配置，再提交发布源码并建立标签。

仓库不通过 GitHub Actions 编译或公证发布版本，不需要在 GitHub Secrets 中保存 Apple 凭据。本文中的版本号和路径都是示例，执行前替换为当次发布值。构建、测试、Git 命令从仓库根目录执行。

## 1. 分工与授权范围

“我”指项目维护者，“Codex”指协助操作仓库的代理。

| 工作 | 默认执行者 | 如何交接或授权 |
| --- | --- | --- |
| 确定版本号、构建号、发布范围 | 我 | 告诉 Codex 确切值以及要发布的功能 |
| 检查源码、修改版本、生成工程、构建测试、整理说明 | Codex | 提出准备发布的任务即可；已授权范围内不必逐条确认 |
| Apple 账号登录、双重认证、选择团队与证书、钥匙串授权 | 我 | 在本机 Xcode 或系统弹窗完成，不把密码或私钥发给 Codex |
| Archive、Direct Distribution、提交公证、导出 App | 我 | 按第 4 节操作，完成后提供导出 App 的路径 |
| 检查导出 App、生成 ZIP 与校验值 | Codex，也可由我执行 | 明确导出路径和目标版本即可 |
| 清理工程中的本机签名配置 | Codex | 明确要求清理；保留功能、版本、资源和其他有效改动 |
| commit、push、创建并推送标签 | Codex，也可由我执行 | 明确授权这些动作，并给出目标分支及标签名 |
| GitHub 创建草稿、上传附件、发布 Release | 我默认手动执行 | 如果交给 Codex，明确仓库、标签、附件，以及只存草稿还是正式发布 |

一次请求可以授权多个连续动作，例如“清理签名配置、commit、push main，并创建推送 v1.1.0 标签”。Codex 在完成检查后执行，不需要每一步再次确认。仅要求写文档、检查或打包，不代表授权推送或公开发布；创建草稿也不等于授权发布。

本机工具若出现文件访问、网络或钥匙串权限弹窗，这是执行环境的权限要求。若被自动审批拦截，Codex 应说明被拦截的具体操作和原因，并继续完成未受阻的工作。

## 2. 日常开发保留哪些配置

持久工程配置维护在 [generate_project.py](../scripts/generate_project.py)，生成的 [project.pbxproj](../Veyra.xcodeproj/project.pbxproj) 一同提交。

| 配置 | 仓库默认值或约定 |
| --- | --- |
| 签名方式 | `CODE_SIGN_STYLE = Manual`，`CODE_SIGN_IDENTITY = "-"`，即 ad-hoc 签名 |
| 开发者身份 | 不保存本机 `DEVELOPMENT_TEAM`、个人证书名称或描述文件选择 |
| Hardened Runtime | Veyra App 的 Debug、Release 开启；VeyraTests 关闭 |
| App Sandbox | 关闭，保持现有本地数据读取设计 |
| User Script Sandboxing | 开启；它限制构建脚本，与 App Sandbox 是不同配置 |
| 系统要求与架构 | macOS 14；Release 产物应包含 `arm64` 和 `x86_64` |
| 应用类别 | `LSApplicationCategoryType = public.app-category.developer-tools` |

这些默认设置可用于本机开发和测试。公开发布使用的最终 App 需要 Developer ID 分发签名与公证。Hardened Runtime 是公证要求，App Sandbox 对这种 App Store 外分发方式可选。[Apple：准备分发配置](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)

签名私钥保存在本机钥匙串中。日常提交不需要把私钥、Apple 密码、公证凭据或 GitHub Token 写入工程；GitHub 登录使用本机已有的凭据管理方式。

## 3. 发布前准备

### 3.1 我先确定发布信息

- 确定版本，例如 `1.1.0`，对应新标签 `v1.1.0`。
- 确定构建号，例如 `2`；重新发布修正版时递增构建号，不覆盖已经公开的旧版本。
- 确定本次发布包含哪些改动，完成基本界面验收。
- 确认 Apple Developer Program 会员资格有效，本机 Xcode 可访问团队，以及带有匹配私钥的 Developer ID Application 证书。账号配置通常只需首次或证书更新时处理。

### 3.2 Codex 检查与准备源码

先检查 `git status`、当前分支及差异，区分有效功能改动与上次遗留的本机签名设置。不能为了得到干净工作区直接丢弃全部未提交内容。

更新 [Info.plist](../Veyra/Info.plist) 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`。版本必须在 Archive 前确定；Xcode 界面填写后也要核对实际保存位置。

在尚未选择本次本机签名身份时生成工程，并运行检查：

```sh
python3 scripts/generate_project.py
VEYRA_DERIVED_DATA_PATH=/tmp/veyra-release-tests ./scripts/test.sh
./scripts/build.sh
```

测试脚本运行 XCTest 和诊断集成检查。检查实际菜单栏在中英文、深浅色、辅助显示选项及滚动场景下的表现，具体命令见[开发检查](development.zh-CN.md#开发检查)。普通 Release 构建用于验证源码；最终上传的是后续从 Organizer 导出的公证 App。

尽量在 Archive 前提交已确认的功能和版本改动，形成可追溯的源码基线；这一步由我执行，或明确授权 Codex commit。若当次仍有待提交源码，应记录归档时的差异，冻结功能、资源和版本，直到完成发布。

### 3.3 核对 Bundle ID

生成脚本的开发默认 Bundle ID 是 `local.codexmonitor.app`。正式分发时必须核对并沿用上一版正式 App 的 Bundle ID；如果上一版为 `com.yuzio.veyra`，本次也使用该值。可以用第 5 节的命令读取上一版 App 确认。

Bundle ID 是公开的应用标识，不是密码。更换它可能影响偏好设置和应用身份。重新生成工程会恢复开发默认值，因此每次进入发布签名步骤都要复核。若希望正式标识成为仓库的持久默认值，应单独修改生成脚本并验证，不在签名清理时顺带改动。

## 4. 我在 Xcode 中执行 Archive、公证与导出

### 4.1 配置本次签名

1. 打开 `Veyra.xcodeproj`，选择 `Veyra` scheme。
2. 在 **Xcode → Settings → Accounts** 登录 Apple 开发者账号；已有有效登录时无需重复。
3. 打开 **Veyra target → Signing & Capabilities**，为本次归档选择正确 Team，并核对正式 Bundle ID。可以让 Xcode 自动管理签名，按提示完成证书与钥匙串授权。
4. 核对 App 的 Hardened Runtime 已开启、App Sandbox 关闭；不把发布签名要求套到 VeyraTests。
5. 在 scheme 的 **Archive** 设置中确认使用 **Release** 配置，选择可用于 Mac 归档的运行目标。若提供 **Any Mac**，可选择它；最终是否为通用二进制仍以导出后架构检查为准。

归档阶段显示 `Apple Development` 不等于最终分发签名错误。Organizer 可以在分发时重新签名；最终导出的 App 必须使用 **Developer ID Application**。单纯打开 Xcode 或选择 Team 不会自动完成公证。[Apple：从 Xcode 导出分发签名的应用](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

### 4.2 归档并提交 Apple

1. 执行 **Product → Archive**，等待成功。
2. 在 **Window → Organizer → Archives** 中选择本次 Veyra 归档，核对版本号和构建号。
3. 点击 **Distribute App → Direct Distribution**，核对签名团队后按向导提交。
4. 按需完成本机认证，不把导出日志或凭据复制到公开仓库。

Direct Distribution 用于 macOS App Store 外的 Developer ID 应用公证。[Apple：选择分发方式](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)

### 4.3 等待公证并导出

| Xcode 状态 | 含义与下一步 |
| --- | --- |
| `Uploaded … to Apple notary service` | 已上传，等待 Apple 处理；尚未完成分发准备 |
| 正在处理 | 保留归档，稍后查看状态；不必反复重新提交 |
| `Ready to distribute` | 本次分发已准备就绪，继续导出公证后的 App |
| 失败或被拒绝 | 查看该次公证日志，修正原因并重新归档、提交 |

在 Organizer 中使用 **Export Notarized App** 或当前 Xcode 提供的对应导出入口，保存到仓库外的独立目录，或被忽略的 `build/releases/v1.1.0/`。按钮名称可能随 Xcode 版本变化。等待时间不固定；该状态不表示已上传 GitHub，也不表示上架 App Store。

保留 `.xcarchive`、dSYM 和导出记录用于本机排错。交给 Codex 的是最终导出的 `Veyra.app` 路径。后续清理源码文件不会改变已有归档或导出 App。

## 5. 检查导出 App 并打包

这一步我可以手动运行，也可以提供路径让 Codex 完成。将下面路径替换成 Organizer 实际导出的位置：

```sh
release_app='/absolute/path/to/export/Veyra.app'

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$release_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$release_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$release_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$release_app/Contents/Info.plist"
lipo -archs "$release_app/Contents/MacOS/Veyra"
codesign --verify --deep --strict --verbose=2 "$release_app"
codesign -dv --verbose=4 "$release_app"
spctl --assess --type execute --verbose=4 "$release_app"
xcrun stapler validate "$release_app"
```

确认结果：

- 版本、构建号和 Bundle ID 与本次发布计划一致，类别为 `public.app-category.developer-tools`。
- 架构包含 `arm64` 和 `x86_64`，才使用 `macos-universal` 附件名称。
- 签名验证成功；签名详情显示 `Developer ID Application`、预期团队和 `runtime` 标志。
- Gatekeeper 评估通过，通常显示 `accepted` 与 `Notarized Developer ID`。
- stapler 验证通过，表明 App 带有可供离线验证的公证票据。

若票据缺失，先确认选择了公证成功的导出产物；必要时对该 App 执行 `xcrun stapler staple "$release_app"`，随后重新验证、打包。签名或公证失败时先排查，不能用关闭 Gatekeeper 的办法作为发布验收。[Apple：自定义公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

打包前运行导出的 App 检查菜单栏基本行为，并退出测试实例。确认没有把仍在运行的旧版本误认为新版本。

```sh
mkdir -p build/releases/v1.1.0
release_zip="$PWD/build/releases/v1.1.0/Veyra-v1.1.0-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$release_app" "$release_zip"
shasum -a 256 "$release_zip"
```

使用新的输出路径，避免混淆旧附件。保存 SHA-256 到发布记录或说明中。ZIP 内应有一个完整的 `Veyra.app`，不需要整个导出目录。打包后不修改 App 内的文件，不用普通开发构建覆盖它；若改动实际应用内容，应重新签名、公证并验证。

## 6. 清理源码中的本机签名设置

建议在导出与验证成功后执行，便于需要时重新导出。技术上清理工程不依赖公证完成：它只影响之后的构建，不会撤销已导出 App 的签名或公证。

我可以直接授权：

> 请清理本次发布留在源码中的本机签名配置，保留功能、资源、版本号和构建号变更；先不要 commit 或 push。

Codex 应按以下顺序处理：

1. 检查所有未提交差异，记录需要保留的配置；必要的备份放在仓库外或忽略目录中。
2. 将有意保留的通用工程改动落实到生成脚本，确保脚本中仍无个人签名身份。
3. 运行 `python3 scripts/generate_project.py` 恢复默认签名配置，再检查生成结果。生成脚本会完整重写工程和共享 scheme，不能代替清理前的差异审阅。
4. 逐项检查 `Info.plist`、工程、scheme 以及当次其他改动，清除实际 Team 值、个人证书名称和本机描述文件选择；保留版本、类别、本地化等有效修改。涉及的文件数量不固定。
5. 检查暂存区、未跟踪文件和本次将推送的提交，防止签名配置或凭据已进入待推送历史。仅在最新提交删掉秘密，不能消除旧提交中的泄露。
6. 核对 App Hardened Runtime 开启、Tests 关闭、Sandbox 和部署目标保持约定，生成结果稳定。

此处“清理证书信息”指清理源码中的本机签名配置，**不删除钥匙串中的证书或私钥，也不清理归档、导出 App 或公证票据**。Xcode 若提示磁盘文件已变更，应重新载入磁盘版本，避免把内存中的旧签名配置再次保存回来。

扫描应覆盖真实秘密内容，而不是机械要求文档中连 `DEVELOPMENT_TEAM` 或 `Token` 这些说明词都不能出现。扫描是检查手段，不能据此保证仓库绝对不存在任何敏感信息。

## 7. commit、push 与发布标签

清理后，确认标签将包含本次归档使用的功能、资源、版本和构建号。允许存在已明确记录的本机签名及分发标识覆盖；源码标签不代表可直接重建出字节完全相同的签名 App。若 Archive 后修改了实际功能、资源或版本，应重新归档，不能把旧 App 配到新源码标签上。

我可以一次授权：

> 请检查并清理本机签名配置，保留本次发布的有效源码变更，commit、push 到 origin/main，并为确认后的发布提交创建和推送 v1.1.0 标签。不要创建或发布 GitHub Release。

Codex 先检查远端和待推送提交，报告实际提交范围。已有明确授权时完成检查后继续执行；发现版本不一致、远端冲突或标签重名时先解决具体问题，不覆盖已发布的旧标签。

手动操作可参考以下顺序。`REVIEWED_FILE`、`RELEASE_COMMIT_SHA` 都必须替换；按实际审阅结果列出文件，避免 `git add .` 把无关改动一起提交：

```sh
git status --short --branch
git diff
git fetch origin
git log --oneline origin/main..HEAD
git log --oneline HEAD..origin/main

git add -- REVIEWED_FILE
git diff --cached --check
git diff --cached
git commit -m "fix: prepare v1.1.0 release"
git rev-parse HEAD

git push origin main
git tag -a v1.1.0 RELEASE_COMMIT_SHA -m "Veyra v1.1.0"
git push origin v1.1.0
git rev-parse 'v1.1.0^{commit}'
git ls-remote origin refs/tags/v1.1.0 'refs/tags/v1.1.0^{}'
```

以上假定当前分支是已核对的 `main`，且远端不存在未整合提交。若前面已经提交完所有发布源码，不需要空提交。比较本地标签解析出的提交 SHA 与远端附注标签的 `^{}` 值，确认一致；分支 push 失败时不要继续发标签。

不强制推送，不移动已经公开使用的标签。需要修正版时创建新版本。推送分支与标签只同步源码，不会自动上传 App 或发布 GitHub Release。

## 8. 我在 GitHub 上传并发布

1. 打开 [Veyra Releases](https://github.com/yuzio-ai/veyra/releases)，点击 **Draft a new release**。
2. 在 **Choose a tag** 选择第 7 节已经推送的新标签，核对对应提交。
3. 填写标题，例如 `Veyra v1.1.0`，写明更新内容、macOS 14+、支持架构及安装方式。
4. 在二进制附件区域上传第 5 节验证过的 ZIP，等待上传完成；GitHub 自动生成的 **Source code** 压缩包是源码，不能代替 App 附件。
5. 先保存草稿并检查附件、标签及说明；正式稳定版不勾选 **This is a pre-release**，需要时设置为最新版本。
6. 确认无误后点击 **Publish release**。启用不可变 Release 的仓库应在发布前上传齐所有附件，因为发布后附件和标签会受到锁定保护。[GitHub：管理 Release](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

发布说明可用以下模板，检查通过后再声称已完成签名与公证：

```markdown
## Changes
- 本次变更说明

## Install
Requires macOS 14 or later. Supports Apple Silicon and Intel Macs.
Download Veyra-v1.1.0-macos-universal.zip, unzip it, and move Veyra.app
to Applications. Veyra runs in the menu bar.

Signed with Developer ID and notarized by Apple.

SHA-256: 填写最终上传的 ZIP 校验值
```

如果改由 Codex 操作，应给出完整授权，例如：

> 请把已验证的 `/absolute/path/to/Veyra-v1.1.0-macos-universal.zip` 上传到 yuzio-ai/veyra 的 v1.1.0 Release，使用已确认的发布说明，保存为草稿，不要发布。

检查草稿后再说“发布这个 v1.1.0 草稿”，或在前一条请求中明确授权正式发布。已有完整发布授权时，不需要额外重复确认。

## 9. 发布后的确认与信息边界

从 Release 页面重新下载 ZIP，对比 SHA-256；解压后复核版本、签名、公证与启动行为。有条件时在另一台满足系统要求的 Mac 上安装，并验证菜单栏入口。下载验收不要通过移除隔离属性或关闭 Gatekeeper 来绕过系统检查。

最终检查清单：

- [ ] Release 标签对应本次归档的有效源码与版本。
- [ ] 附件是 Organizer 导出的公证 App，ZIP 校验值与下载文件一致。
- [ ] 普通用户能从 Releases 下载、解压并运行，无需 Xcode。
- [ ] 源码保留默认开发配置，未提交本机签名身份或真实凭据。
- [ ] 归档、dSYM 和本机发布记录已保留，未误传为公开附件。

源码与产物的信息边界不同：

| 内容 | 处理方式 |
| --- | --- |
| Team ID、Developer ID 证书主体中的个人或组织名称 | 不写入仓库的本机配置；正式签名 App 中可被查看，属于公开签名身份 |
| Bundle ID、版本号、公证与签名元数据 | 可存在于公开 App 中，不属于秘密 |
| Git 提交者姓名与邮箱 | 公开提交历史中可见；本项目维护者接受公开个人邮箱 |
| 签名私钥、`.p12`、Apple 密码、公证密钥、GitHub Token | 不进入源码、日志、聊天或 Release 附件 |
| `.xcarchive`、dSYM、导出日志、描述文件、钥匙串文件 | 默认仅本机保存，不作为用户下载附件 |

这是一套正常的本机签名、公证与手动分发工程流程。它保护私钥和账号凭据，但不能隐藏正式签名应用的开发者身份；不要为了隐藏姓名而删除 App 的签名。[Apple：公证与 Developer ID](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 10. 常见问题

| 现象 | 处理方式 |
| --- | --- |
| Xcode 提示 `Update to recommended settings` | 对比具体建议，把需要长期保留的配置落实到生成脚本并生成工程。直接点 Perform Changes 只修改工程，之后可能被脚本覆盖 |
| 提示 `No App Category is set` | 检查 `LSApplicationCategoryType` 与 target 的对应 Info.plist 设置；本项目使用 Developer Tools。检查新构建产物，必要时重新载入工程并清理构建；旧归档不会自动更新 |
| 公证一直在处理 | 查看 Organizer 状态；失败时查该次日志。不要把“上传成功”当作“公证通过” |
| 清理后 Xcode 又出现 Team | 检查是否把旧内存状态写回工程，重新载入磁盘版本再检查差异 |
| 清理后构建变回 ad-hoc | 这是默认开发配置；下一次正式发布时重新选择本机签名，已导出的 App 不受影响 |
| Archive 后修改了版本或实际应用内容 | 重新归档、公证和导出，更新附件与校验值 |
| 已发布版本发现问题 | 准备新版本和新标签；不把旧标签移到新源码，也不悄悄替换旧产物 |

日常命令与诊断见[开发文档](development.zh-CN.md)，用户安装与界面行为见[使用指南](user-guide.zh-CN.md)。


## 11. 应用内版本检查

应用直接读取公开仓库的最新正式 Release，无需额外更新服务器或清单。发布时保持以下约定：

- 标签使用 `vX.Y.Z`，与 App 的 `CFBundleShortVersionString` 一致。检查按数字比较显示版本；只增加 `CFBundleVersion` 不会触发新版提示。
- 先上传并核验 App 安装包，再发布正式 Release 并设置为 Latest。草稿和预发布版本不会提示。
- 应用默认在启动或打开菜单时按 24 小时间隔自动检查；设置中可以关闭或手动检查。检查失败同样进入自动检查间隔，手动检查有 60 秒冷却并遵守 GitHub 限流时间。
- 发现新版后，用户点击“前往下载”进入该版本页面，下载后退出旧版并手动替换 App。现有签名、公证和打包步骤继续适用。
- 未包含更新检查功能的旧版，需要用户先手动升级一次。发布后用较旧显示版本的测试 App 验证新版提示及具体 Release 链接，不为测试修改已发布标签或产物。
