# 设置窗口实施验证

2026-11-06。作者检查通过；尚未执行独立 review 或整体人工验收。未安装替换、提交、推送或发布。

## 结果

| 检查 | 最终结果 |
|---|---|
| XCTest | 257 项通过，0 失败；含 8 项新增窗口几何回归 |
| 脚本回归 | 51 项通过；隔离诊断、语言和配置检查通过 |
| 双语设置预览 | 英文、简体中文各 56 张，共 112 张；覆盖浅色、深色及增强对比度外观 |
| 原生控件程序化检查 | 每语言 31 项通过；宽度伸展及封顶、编辑器/录制控件身份、窄布局无横向溢出、滚动到底部、frame 保存/恢复及无效记录回退 |
| Release | 无签名构建、Release 配置检查及 AX reader 编译通过；未运行外部 AX 读取 |
| 作者静态检查 | 生产固定 autosave 名、预览不持久化、唯一测试名称清理、显式最小尺寸、观察注册及关闭清理；git diff --check 通过 |

来源：[机器可读证据摘要及源码指纹](assets/evidence.json)、[英文控件检查](assets/en-settings-native-checks.json)、[中文控件检查](assets/zh-settings-native-checks.json)。原始日志由本机交付保留，以上必要结果及图片不依赖临时目录即可阅读。

## 图片检查

作者读取了默认浅色、深色增强对比度、窄布局顶部及中英文窄布局底部位图。默认三组设置与标准控件保留；400 pt 窄布局的操作纵向排列，底部检查更新按钮完整可见。

- [默认浅色](assets/default-light-zh.png)
- [深色与增强对比度](assets/default-dark-contrast-zh.png)
- [窄布局顶部](assets/compact-top-zh.png)
- [窄布局底部](assets/compact-bottom-zh.png)
- [最小高度滚动](assets/minimum-scroll-zh.png)
- [无效路径草稿](assets/invalid-draft-en.png)

## 复现

使用 macOS 27.0.1（26A434）、Xcode 27.2（27B52）。以下固定入口在沙箱外执行，使用无签名构建、隔离偏好和临时路径：

```sh
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py test
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py previews settings --language both
/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py release-build
```

最终运行 ID：test `20261106T124243Z-d0718dca`；previews `20261106T124324Z-21a34d65`；release `20261106T124451Z-680f80ec`。

补充检查曾因把 SwiftUI Button 当作 NSButton 查找而失败。修正为检查真实滚动视口底部，并核对底部截图；最终双语检查全部通过。该失败来自检查代码，不代表设置按钮不存在。

## 证据边界与后续审查

显示器选择和断开回退由可注入几何回归覆盖，尚未人工热插拔真实显示器。跨启动持久化通过保存后重新创建 NSWindow 验证，未重启真实 Veyra 进程。关闭后重新打开、键盘、编辑器和快捷键录制使用程序化原生控件检查，不等同于人工键盘或 VoiceOver 验收。

浅色、深色及增强对比度为隔离外观夹具；未切换系统“降低透明度”等真实偏好。标准背景没有引入自定义透明层，但这项源码事实不代表已完成该系统设置下的运行验收。布局位图不证明窗口合成器材质。

下一步审查固定候选的 showSettings → 建窗/恢复 → 打开校正 → 屏幕通知 → 关闭清理路径，以及窄布局的控件身份。当前无独立审查或总体 acceptance passed 结论。
