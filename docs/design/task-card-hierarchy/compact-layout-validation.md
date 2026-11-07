# 紧凑任务卡片实现与验证记录

2026-11-06。范围为已确认的路径隐藏、两行进展、统计分区留白、11pt semibold 标题及 8pt 主要块间距。数据读取、任务归属、统计口径和持久化格式未变。实现由同一作者完成并自检，尚未独立评审、提交或发布。

## 高度与截图

使用同一组固定父子任务、360pt 宽度、固定日期和相同屏幕上限比较。下表为 SwiftUI 实测正文内容高度，单位 pt，包含保持不变的额度等夹具内容；不是面板像素高度，也不是对任意真实任务的固定节省承诺。

| 语言 | 展开状态 | 修改前 | 修改后 | 减少 |
|---|---|---:|---:|---:|
| 中文 | 均收起 | 685 | 636 | 49 |
| 中文 | 仅父任务展开 | 891 | 817 | 74 |
| 中文 | 父子均展开 | 1120 | 1019 | 101 |
| 英文 | 均收起 | 698 | 649 | 49 |
| 英文 | 仅父任务展开 | 924 | 850 | 74 |
| 英文 | 父子均展开 | 1206 | 1072 | 134 |

| 中文固定夹具 | 修改前 | 修改后 |
|---|---|---|
| 均收起 | [截图](compact-layout-assets/before-collapsed.png) | [截图](compact-layout-assets/after-collapsed.png) |
| 仅父任务展开 | [截图](compact-layout-assets/before-parent-expanded.png) | [截图](compact-layout-assets/after-parent-expanded.png) |
| 父子均展开 | [截图](compact-layout-assets/before-both-expanded.png) | [截图](compact-layout-assets/after-both-expanded.png) |

上述 PNG 均为未修改的运行布局快照，不是生成图；其不透明布局便于检查文字、分组和缩进，不包含完整系统玻璃合成。对应[测量数据](compact-layout-assets/measurements.json)保留各状态和行为结果。

中英文各比较 204 项布局，其中 148 项为 360pt 菜单正文，56 项为 570pt 设置窗口。148 项菜单的正文高度均未增加超过 1pt 测量容差；无路径、无进展的 single-light 场景也未变高。完整逐项值见[布局比较](compact-layout-assets/layout-comparison.json)。菜单检查保持 360pt 宽度，长名称、数值和深层任务未撑宽面板。

## 自动检查

| 检查 | 本轮结果 |
|---|---|
| 完整 test | 249 项 XCTest、40 项本地验证入口脚本回归、11 项能耗脚本回归均通过；隔离诊断及配置检查通过 |
| 中英文任务卡片与布局 | 两种语言渲染分项均通过；父子独立展开、重新排序快照后保留展开状态、Space/Return、收起恢复高度、长值、说明浮层 Escape 与焦点恢复均通过 |
| 进展边界 | 短操作一行；含换行的长文本最多两行；空白进展与无进展高度相同；恢复原进展后高度恢复 |
| 文本与路径 | 新增 3 项 XCTest 覆盖换行折叠、完整原文保留、可选路径悬停、本地化冒号和辅助功能补充文案；原标题回退回归继续通过 |
| 六种原生外观 | 浅色、深色、两种增强对比度、两种降低透明度的固定原生弹窗自动检查全部通过；核对实际外观解析、顶部/中部/底部滚动、动态收缩、Escape 和焦点恢复 |
| Release | 无签名通用 Release 构建及产物配置检查通过；配置检查 98 项、0 失败、1 项跳过；辅助 AX 读取工具仅编译，未执行外部 AX 读取 |

[六种原生检查数据](compact-layout-assets/native-checks.json)保留各外观和步骤。自动检查所用实际工具链为 Xcode 27.2（27B52）、Swift 6.4.2；项目部署目标和构建配置未变。

进展实测中，短文本与长文本相差 14pt；空白与缺失内容完全同高。卡片不再显示独立路径，原文与路径仍通过悬停及辅助功能补充信息提供。两个统计标题已加重，统计区内部无横线，父子边界线与统一缩进仍保留。

## 执行范围与限制

所有构建和自动检查通过仓库固定入口非沙箱执行，使用无签名构建及隔离夹具：

```sh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews menu --language both
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews menu --native-only --language en
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py release-build
```

- test：`20261106T112159Z-173f178f`，整轮 passed。
- 双语预览：`20261106T112259Z-2c516201`，中英文布局分项完成；原生浅色通过后，深色因前台应用切换触发 `backgroundSetupFailed`，整轮仍为 failed，不将部分结果冒充完整命令成功。
- 用户确认可以保持前台焦点后，原生专项补验 `20261106T112925Z-70a19232` 整轮 passed，补齐六种外观；未改源码，复用前一轮已完成的双语布局证据，不重跑无关渲染。
- Release：`20261106T112803Z-f2e69fa4`，整轮 passed。
- 修改前双语布局来自 `20261106T111254Z-62c7339b`，其原生检查也被焦点切换中断，不作为整轮成功证据。补采父任务独立展开的 `20261106T111755Z-f3a30459` 在目标截图与高度记录生成后主动中断，只用作基线采样，不声称预览通过。补采时仅增加快照保存点，生产视图未变。

当前证据覆盖实现的作者自动检查和布局核查。原生检查图中的透明材质使用离屏布局位图，不能完整呈现 WindowServer 合成层；系统玻璃材质、实体键鼠及人工 VoiceOver 仍未验收。原生辅助功能焦点断言、单元测试中的文案检查不替代人工读屏。本记录不宣布正式 validate 通过或独立 review 完成。
