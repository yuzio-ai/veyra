# 发布说明规范

发布正文（GitHub Release notes）的样式固定在 [.github/RELEASE_NOTES_TEMPLATE.md](../.github/RELEASE_NOTES_TEMPLATE.md)，由脚本强制：新说明从骨架生成，写完用检查器校验，任何偏离固定样式的写法都不能通过。这样每个版本的发布说明长得一样，也不会在某个版本悄悄漂移。

## 文件组成

| 文件 | 作用 | 移植到其他仓库 |
| --- | --- | --- |
| [.github/RELEASE_NOTES_TEMPLATE.md](../.github/RELEASE_NOTES_TEMPLATE.md) | 固定样式的唯一来源：骨架加写作提示 | 按目标产品改写样板文字 |
| [.github/release-notes.conf](../.github/release-notes.conf) | 仓库相关配置：slug、产品名、目录、附件名、语言块 | **只改这一个文件** |
| [scripts/release-notes-lib.sh](../scripts/release-notes-lib.sh) | 配置加载器，两个脚本都 source 它 | 原样拷贝 |
| [scripts/render-release-notes.sh](../scripts/render-release-notes.sh) | 生成 `<NOTES_DIR>/v<版本>.md` 骨架 | 原样拷贝 |
| [scripts/check-release-notes.sh](../scripts/check-release-notes.sh) | 固定样式检查器 | 原样拷贝 |

三个脚本不含任何仓库特定值；所有仓库相关值都来自 `.github/release-notes.conf`。

说明正文存放在 `NOTES_DIR`（本仓库 `docs/releases/`）：一个 tag 一个文件，文件名必须是 `v<major>.<minor>[.<patch>].md`，并与文内变更链接的 tag 一致。

## 固定样式（检查器强制的不变量）

1. 多语言说明以语言导航行开头（第一个非空行），语言块按 `LANGUAGES` 配置顺序排列，每块之前有 `<a id="..."></a>` 锚点；单语言说明没有导航行、锚点和 `## ` 语言标题。
2. 标题级别只有两种：`##` 语言、`###` 小节，不允许更深或更浅的标题。
3. 小节名只能取自该语言的词表，并保持词表顺序，不得重复或调序。
4. 词表中标记为 required 的小节必须存在（本仓库：系统要求 / 安装）。
5. 每个保留的小节必须有内容——用不到的小节整节删除。
6. 每个语言块以变更链接收尾：`compare/<上一 tag>...<tag>`；`NOTES_DIR` 里最旧的那份说明是首个版本，允许用 `commits/<tag>`。链接中的 tag 必须等于文件名。
7. 发布附件名恒为 `ASSET_NAME`，不带版本号：禁止 `<名字>-<数字>` 形式的带版本变体。

写完的正式说明还要求：没有遗留的 `{{...}}` 占位符；没有 `<!-- -->` 写作提示（代码围栏里的 `<!--` 是内容，允许保留）。检查器只管样式，事实正确性（附件是否真的叫这个名、校验值是否对）由作者负责。

## 模板与占位符

- `{{PRODUCT}}`、`{{VERSION}}`、`{{ASSET}}`、`{{CHANGELOG_URL}}` 由 `render-release-notes.sh` 替换；
- `{{ONE_LINE_SUMMARY}}` / `{{一句话概述}}` 手写一句话概述；
- 系统要求 / 安装、语言锚点、收尾变更行是样板文字，逐字保留，不逐版本改写；
- 其余 `###` 小节按需保留，没有内容的整节删除；
- 结构骨架由 `check-release-notes.sh --skeleton` 校验，因此模板本身永远是合规样例。

## .github/release-notes.conf

| 变量 | 含义 |
| --- | --- |
| `REPO_SLUG` | `owner/repo`，用于拼变更链接。留空时从 `origin` 远程推导（兼容 `git@github.com:...` 与 `https://...` 两种地址） |
| `PRODUCT_NAME` | 替换 `{{PRODUCT}}` 的产品名；留空用仓库名 |
| `NOTES_DIR` | 说明目录，相对仓库根目录 |
| `ASSET_NAME` | 发布附件名，不得携带版本号 |
| `LANGUAGES` | 语言块数组，见下 |

`REPO_SLUG` 在说明发布之后要钉死成字面值：变更链接一经发布就不能变，远程地址将来若变化，写死的值保证检查器期望的链接不跟着漂移。

`LANGUAGES` 每个条目 6 个字段，用 `|` 分隔：

```
id|anchor|heading|marker|vocabulary|required
```

1. `id`：检查器消息里的语言前缀；
2. `anchor`：`<a id="...">` 与导航行 `href` 的目标；
3. `heading`：`## ` 语言标题；
4. `marker`：该语言块收尾变更行的行首字面量（URL 之前的部分）；
5. `vocabulary`：小节名列表，逗号分隔，是唯一允许的顺序；
6. `required`：词表的 0 起下标，这些小节必须存在。

两个及以上条目 → 多语言形态（导航行 + 锚点 + `## ` 语言标题）；恰好一个条目 → 单语言形态（没有导航行、锚点和语言标题，只有 `###` 小节和一行变更链接）。单语言形态下字段 2、3 不生效，但仍建议写全，便于将来加第二语言。

## 日常工作流

```sh
scripts/render-release-notes.sh 1.4.0          # 生成 docs/releases/v1.4.0.md 骨架
# 填写正文，删掉用不到的小节与全部 <!-- 提示 -->
scripts/check-release-notes.sh docs/releases/v1.4.0.md
git add docs/releases/v1.4.0.md
gh release create v1.4.0 Veyra.zip --title v1.4.0 --notes-file docs/releases/v1.4.0.md
```

- 发布标题恒等于 tag（如 `v1.4.0`），不要手打别的标题；附件使用不带版本号的 `ASSET_NAME`。
- `render-release-notes.sh` 从 git tag 解析上一个版本拼变更链接；tag 已存在时拒绝生成（说明应当早已提交）。
- `render-release-notes.sh --stdout` 只打印不落盘；`--self-test` 校验模板骨架，不需要任何 tag。
- `check-release-notes.sh` 不带参数检查 `NOTES_DIR` 下全部说明；也可指定若干文件；`--skeleton <file>` 只校验骨架，允许占位符、空小节和提示注释。全部通过退出码 0，任意一项失败退出码 1。
- 发布前必须跑一遍检查器；将来接入 CI 时直接调用同一命令即可。

## 移植到其他仓库

1. 拷贝 `scripts/release-notes-lib.sh`、`scripts/render-release-notes.sh`、`scripts/check-release-notes.sh` 与 `.github/` 下的模板和配置；三个脚本保持原样。
2. 只编辑 `.github/release-notes.conf`：`REPO_SLUG`、`PRODUCT_NAME`、`NOTES_DIR`、`ASSET_NAME`、`LANGUAGES`。
3. 按目标产品改写模板里的样板文字（系统要求 / 安装、各小节提示语），改完跑 `scripts/render-release-notes.sh --self-test` 确认骨架仍合规。
4. 发布过第一份说明后，把 `REPO_SLUG` 钉死为字面值。

## 本仓库的既有说明

`docs/releases/` 里 v1.0.0–v1.3.0 的说明已按本规范整理过结构，其中 v1.0.0 依据 GitHub 上已发布的正文整理。其中 v1.2.1、v1.3.0 的安装小节保留了当时实际发布的带版本附件名（`Veyra-vX.Y.Z-macos-universal.zip`），是既成事实；从新版本起一律使用不带版本号的 `Veyra.zip`。
