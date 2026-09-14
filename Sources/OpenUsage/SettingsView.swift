import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var traeAccounts: TraeAccountStore
    @AppStorage("autoCaptureCurrentAccount") private var autoCapture = false
    @AppStorage("refreshIntervalMinutes") private var refreshInterval = 10
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var backupPasswordPanel: BackupPasswordPanel?

    init(state: AppState) {
        self.state = state
        _traeAccounts = ObservedObject(wrappedValue: state.traeAccounts)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionTitle(
                    title: "设置",
                    subtitle: "WorkBuddy Switch \(appVersion) · \(state.selectedProvider.title)"
                )

                settingsSection("常规") {
                    Toggle("登录时启动 WorkBuddy Switch", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { enabled in
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                                state.present(error, title: "登录项设置失败")
                            }
                        }
                    Toggle(
                        "启动时保存当前 \(state.selectedProvider.title) 账号",
                        isOn: $autoCapture
                    )
                    HStack {
                        Text("完整刷新间隔")
                        Spacer()
                        Picker("完整刷新间隔", selection: $refreshInterval) {
                            Text("5 分钟").tag(5)
                            Text("10 分钟").tag(10)
                            Text("30 分钟").tag(30)
                            Text("60 分钟").tag(60)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }

                settingsSection("客户端与安装路径") {
                    statusRow(
                        title: "WorkBuddy",
                        detail: workBuddyApplicationURL?.path ?? "未安装",
                        available: workBuddyApplicationURL != nil
                    )
                    statusRow(
                        title: "Trae CN",
                        detail: traeApplicationURL(.china)?.path ?? "未安装",
                        available: traeApplicationURL(.china) != nil
                    )
                    statusRow(
                        title: "TRAE Work",
                        detail: traeApplicationURL(.work)?.path ?? "未安装",
                        available: traeApplicationURL(.work) != nil
                    )
                }

                settingsSection("\(state.selectedProvider.title) 数据源") {
                    if let variant = state.selectedTraeVariant {
                        let storageURL = TraeDataLocation.resolve(variant).storageURL
                        statusRow(
                            title: "登录数据",
                            detail: storageURL.path,
                            available: FileManager.default.fileExists(
                                atPath: storageURL.path
                            )
                        )
                        Label(
                            "Token 与额度来自 \(variant.displayName) 官方 API",
                            systemImage: "network"
                        )
                    } else {
                        statusRow(
                            title: "会话数据库",
                            detail: AppPaths.workBuddyDatabase.path,
                            available: FileManager.default.fileExists(
                                atPath: AppPaths.workBuddyDatabase.path
                            )
                        )
                        statusRow(
                            title: "Token 记录",
                            detail: AppPaths.workBuddyProjects.path,
                            available: FileManager.default.fileExists(
                                atPath: AppPaths.workBuddyProjects.path
                            )
                        )
                    }
                }

                settingsSection("隐私") {
                    Label(
                        "三个客户端的账号快照均存储在 macOS 钥匙串",
                        systemImage: "lock.shield"
                    )
                    Label(
                        "WorkBuddy Token 在本机解析；Trae 用量读取官方 API",
                        systemImage: "internaldrive"
                    )
                    Label(
                        "Trae 切号不会删除设置、插件、工作区或对话",
                        systemImage: "checkmark.shield"
                    )
                }

                settingsSection("账号数据") {
                    backupActionRow(
                        title: "导出全部账号",
                        systemImage: "square.and.arrow.up",
                        note: "将三端已保存的账号快照加密导出为文件",
                        action: beginExport
                    )
                    backupActionRow(
                        title: "导入账号",
                        systemImage: "square.and.arrow.down",
                        note: "从备份文件恢复账号，已存在的将跳过",
                        action: beginImport
                    )
                }

                HStack {
                    Link(
                        "GitHub",
                        destination: URL(
                            string: "https://github.com/koi128bit/WorkBuddy-Switch"
                        )!
                    )
                    Spacer()
                    Text("非 WorkBuddy 或 Trae 官方产品")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(28)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert(item: $state.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    @MainActor
    private func beginExport() {
        guard state.canStartAccountBackup, backupPasswordPanel == nil else { return }
        guard state.hasAnySavedAccount else {
            state.alert = AppAlert(
                title: "无法导出",
                message: "当前没有已保存的账号，请先在各客户端登录并保存账号。"
            )
            return
        }
        // 独立可激活的 NSPanel（activation 门控 + 显式 first responder），
        // 确保键盘焦点真正转移到密码框；presenter 由本视图强持有。
        let presenter = BackupPasswordPanel()
        backupPasswordPanel = presenter
        presenter.presentExport { [weak presenter] password in
            if backupPasswordPanel === presenter { backupPasswordPanel = nil }
            continueExport(password: password)
        } onCancel: { [weak presenter] in
            if backupPasswordPanel === presenter { backupPasswordPanel = nil }
        }
    }

    @MainActor
    private func continueExport(password: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.workBuddySwitchBackup]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue =
            "WorkBuddy-Switch-账号备份-\(formatter.string(from: Date())).wbsacct"
        panel.message = "备份文件使用导出密码加密，密码无法找回，请妥善保管。"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await state.exportAllAccounts(to: url, password: password)
        }
    }

    @MainActor
    private func beginImport() {
        guard state.canStartAccountBackup, backupPasswordPanel == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.workBuddySwitchBackup, .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let presenter = BackupPasswordPanel()
        backupPasswordPanel = presenter
        presenter.presentImport { [weak presenter] password in
            if backupPasswordPanel === presenter { backupPasswordPanel = nil }
            Task {
                await self.state.importAccounts(from: url, password: password)
            }
        } onCancel: { [weak presenter] in
            if backupPasswordPanel === presenter { backupPasswordPanel = nil }
        }
    }

    private func backupActionRow(
        title: String,
        systemImage: String,
        note: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if state.isAccountBackupBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label(title, systemImage: systemImage)
                }
                .frame(minWidth: 150, alignment: .leading)
            }
            .controlSize(.large)
            .disabled(!state.canStartAccountBackup || state.isAccountBackupBusy || backupPasswordPanel != nil)
            Spacer()
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workBuddyApplicationURL: URL? {
        WorkBuddyController().applicationURL
    }

    private func traeApplicationURL(_ variant: TraeVariant) -> URL? {
        traeAccounts.applicationURL(for: variant)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 13) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(OpenUsageColors.separator, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func statusRow(title: String, detail: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(available ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(available ? "可用" : "不可用")，\(detail)")
    }
}

extension UTType {
    /// WorkBuddy Switch 账号备份文件类型（加密容器）。
    static var workBuddySwitchBackup: UTType {
        UTType(exportedAs: "com.koi128bit.openusage.wbsacct", conformingTo: .data)
    }
}
