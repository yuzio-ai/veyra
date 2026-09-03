import SwiftUI
import AppKit

struct MonitorSettings: View {
    @Bindable var store: MonitorStore
    @State private var home = ""
    @State private var executable = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                VeyraIcon(size: 32)
                Text("沿用 Codex 的登录与本机任务记录。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            pathField("Codex 数据目录", value: $home, placeholder: CodexLocation.resolve().home.path, folder: true)
            pathField("Codex 可执行文件", value: $executable, placeholder: CodexLocation.resolve().executable?.path ?? "自动查找", folder: false)
            Text("留空即可自动查找。菜单打开或有运行任务时每 5 秒检查，空闲时每 30 秒检查。额度默认读取本地快照，仅点击「联网校准」时请求账号额度。应用不会启动模型请求。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if saved { Label("已保存，正在刷新", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("恢复自动查找") { home = ""; executable = ""; saved = false }
                Button("保存") { store.saveSettings(home: home, executable: executable); saved = true }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26).frame(width: 570)
        .onAppear { home = store.homePath; executable = store.executablePath }
    }

    private func pathField(_ title: String, value: Binding<String>, placeholder: String, folder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.medium))
            HStack {
                TextField(placeholder, text: value).textFieldStyle(.roundedBorder)
                    .onChange(of: value.wrappedValue) { saved = false }
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
                    panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
                    panel.message = title
                    if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path; saved = false }
                }
            }
        }
    }
}
