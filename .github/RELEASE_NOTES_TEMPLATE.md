<!--
Release notes — canonical template (pinned style).

The structure is fixed so every release body looks the same:

  - language order follows LANGUAGES in .github/release-notes.conf;
  - heading levels: ## for a language, ### for a section — nothing deeper;
  - one vocabulary per language for sections, always in the order listed below:
      New / 新增                Changed / 变更
      Fixed / 修复              How it works / 实现方式
      Engineering / 工程质量    Known limitations / 已知限制
      Requirements / 系统要求   Installation / 安装   (both required)
  - Requirements / Installation, the language anchors, and the trailing
    changelog line are boilerplate: keep them verbatim.
  - the asset is always called {{ASSET}} (the release asset has no version).

{{PRODUCT}}, {{VERSION}}, {{ASSET}} and {{CHANGELOG_URL}} are substituted by
scripts/render-release-notes.sh; {{ONE_LINE_SUMMARY}} / {{一句话概述}} you fill
in by hand.

Workflow:

    scripts/render-release-notes.sh 1.2.0      # write <NOTES_DIR>/v1.2.0.md
    # fill in the prose, delete the sections you do not need
    scripts/check-release-notes.sh <NOTES_DIR>/v1.2.0.md
    gh release create v1.2.0 {{ASSET}} --title v1.2.0 --notes-file <NOTES_DIR>/v1.2.0.md

scripts/check-release-notes.sh enforces all of the above; run it before every publish.
-->

<a href="#english">English</a> | <a href="#简体中文">简体中文</a>

<a id="english"></a>
## English

{{PRODUCT}} {{VERSION}} {{ONE_LINE_SUMMARY}}.

### New

<!-- One bullet per user-visible addition: "- **Phrase** — detail." Delete the section if there is nothing new. -->

### Changed

<!-- One bullet per user-visible behaviour change. Delete the section if there is none. -->

### Fixed

<!-- One bullet per user-visible fix. Delete the section if there are none. -->

### How it works

<!-- Optional: the mechanism behind a non-obvious feature. Delete the section if it is not needed. -->

### Engineering

<!-- Optional: scripts, CI, fixtures, refactors. Not user-visible. Delete the section if there is none. -->

### Known limitations

<!-- Optional: the honest limits of this build. Delete the section if there are none. -->

### Requirements

- macOS 14 or later. Supports Apple Silicon and Intel Macs.

### Installation

1. Download `{{ASSET}}` from the assets below
2. Unzip, quit the running {{PRODUCT}} app, and replace the old version in Applications
3. Relaunch {{PRODUCT}}

**Full changelog**: {{CHANGELOG_URL}}

<a id="简体中文"></a>
## 简体中文

{{PRODUCT}} {{VERSION}} {{一句话概述}}。

### 新增

<!-- 每个用户可见的新增一条：「- **短语** —— 说明。」没有就删掉本节。 -->

### 变更

<!-- 每个用户可见的行为变化一条。没有就删掉本节。 -->

### 修复

<!-- 每个用户可见的修复一条。没有就删掉本节。 -->

### 实现方式

<!-- 可选：非直观功能背后的机制。不需要就删掉本节。 -->

### 工程质量

<!-- 可选：脚本、CI、fixture、重构。用户不可见。没有就删掉本节。 -->

### 已知限制

<!-- 可选：这一版诚实的边界。没有就删掉本节。 -->

### 系统要求

- macOS 14 或更高版本，支持 Apple Silicon 和 Intel Mac。

### 安装

1. 下载下方 Assets 中的 `{{ASSET}}`
2. 解压后退出正在运行的 {{PRODUCT}}，将新版本移入「应用程序」目录并替换旧版本
3. 重新启动 {{PRODUCT}}

**完整变更**：{{CHANGELOG_URL}}
