import Foundation

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: AppSection = .overview
    @Published var selectedProvider: ManagedProvider = .workBuddy
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var usage: UsageSnapshot = .empty
    @Published private(set) var quota: QuotaSnapshot?
    @Published private(set) var traeQuota: TraeQuotaSummary?
    @Published private(set) var locallyAttributedCycleCredits: Double?
    @Published private(set) var quotaMessage: String?
    @Published private(set) var sessionMessage: String?
    @Published private(set) var usageMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isUsageRefreshing = false
    @Published private(set) var usagePeriod: UsagePeriod = .today
    @Published private(set) var usageStartDate: Date
    @Published private(set) var usageEndDate: Date
    @Published private(set) var resumingSessionID: String?
    @Published var usageAccountID: String?
    @Published var alert: AppAlert?
    @Published private(set) var isAccountBackupBusy = false

    let accounts = AccountStore()
    let traeAccounts = TraeAccountStore()
    private let sessionStore = SessionStore()
    private let usageService = UsageService()
    private let traeUsageService = TraeUsageService()
    private let workBuddy = WorkBuddyController()
    private let accountBackup = AccountBackupService()
    private var startupTask: Task<Void, Never>?
    private var localRefreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    private var usageGeneration: UInt64 = 0

    init() {
        let today = Calendar.current.startOfDay(for: Date())
        usageStartDate = today
        usageEndDate = today
        if
            let rawProvider = UserDefaults.standard.string(
                forKey: "selectedManagedProvider"
            ),
            let restoredProvider = ManagedProvider(rawValue: rawProvider)
        {
            selectedProvider = restoredProvider
        }
    }

    deinit {
        startupTask?.cancel()
        localRefreshTask?.cancel()
        autoRefreshTask?.cancel()
    }

    var usageDateRange: UsageDateRange {
        usagePeriod.dateRange(
            customStart: usageStartDate,
            customEnd: usageEndDate
        )
    }

    var selectedTraeVariant: TraeVariant? {
        selectedProvider.traeVariant
    }

    var activeAccountCount: Int {
        guard let variant = selectedTraeVariant else {
            return accounts.accounts.count
        }
        return traeAccounts.accounts(for: variant).count
    }

    var activeCurrentUserID: String? {
        guard let variant = selectedTraeVariant else {
            return accounts.currentUserID
        }
        return traeAccounts.currentUserID(for: variant)
    }

    var activeCurrentAccountName: String? {
        guard let variant = selectedTraeVariant else {
            return accounts.currentAccount?.nickname
        }
        return traeAccounts.currentAccount(for: variant)?.nickname
    }

    var activeCurrentAccountShortID: String? {
        guard let variant = selectedTraeVariant else {
            return accounts.currentAccount?.shortID
        }
        return traeAccounts.currentAccount(for: variant)?.shortID
    }

    var isActiveAccountSwitching: Bool {
        guard let variant = selectedTraeVariant else {
            return accounts.isSwitching
        }
        return traeAccounts.isSwitching(variant)
    }

    func selectProvider(_ provider: ManagedProvider) {
        guard provider != selectedProvider else { return }
        invalidateRefreshResults()
        selectedProvider = provider
        UserDefaults.standard.set(
            provider.rawValue,
            forKey: "selectedManagedProvider"
        )
        usageAccountID = nil
        sessions = []
        usage = .empty
        quota = nil
        traeQuota = nil
        locallyAttributedCycleCredits = nil
        sessionMessage = provider.supportsSessions
            ? nil
            : "\(provider.title) 暂不支持对话浏览或恢复。"
        usageMessage = nil
        quotaMessage = "正在读取 \(provider.title) 用量。"
        Task { @MainActor [weak self] in
            await self?.refreshAll(force: true)
        }
    }

    func start() async {
        if let startupTask {
            await startupTask.value
            return
        }

        let task = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.performStartup()
        }
        startupTask = task
        await task.value
    }

    private func performStartup() async {
        if UserDefaults.standard.bool(forKey: "autoCaptureCurrentAccount") {
            if let variant = selectedTraeVariant {
                _ = try? traeAccounts.captureCurrent(variant)
            } else {
                _ = try? accounts.captureCurrent()
            }
        }

        localRefreshTask = Task { @MainActor [weak self] in
            await self?.localRefreshLoop()
        }
        autoRefreshTask = Task { [weak self] in
            await self?.autoRefreshLoop()
        }

        await refreshAll()
        if selectedTraeVariant != nil {
            return
        }

        for delay in [300_000_000, 900_000_000, 1_800_000_000] as [UInt64] {
            guard sessions.isEmpty || usage.scannedFiles == 0 || usageMessage != nil else {
                break
            }
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            if sessions.isEmpty {
                await reloadSessions()
            }
            if usage.scannedFiles == 0 || usageMessage != nil {
                await refreshUsageIfIdle(force: true)
            }
        }
    }

    func refreshAll(force: Bool = false) async {
        if let variant = selectedTraeVariant {
            await refreshTraeAll(variant: variant, force: force)
            return
        }

        traeQuota = nil
        refreshGeneration &+= 1
        sessionGeneration &+= 1
        usageGeneration &+= 1
        let generation = refreshGeneration
        let sessionRequest = sessionGeneration
        let usageRequest = usageGeneration
        let range = usageDateRange
        let accountID = usageAccountID
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }
        accounts.refreshCurrentAccount()
        if let quota, quota.sourceUserID != accounts.currentUserID {
            self.quota = nil
            locallyAttributedCycleCredits = nil
            quotaMessage = "账号已变更，正在刷新额度。"
        }

        do {
            let store = sessionStore
            let loadedSessions = try await Task.detached(priority: .utility) {
                try store.loadSessions(includeDeleted: true)
            }.value
            guard
                refreshGeneration == generation,
                sessionGeneration == sessionRequest
            else {
                return
            }
            sessions = loadedSessions
            sessionMessage = nil
        } catch {
            guard
                refreshGeneration == generation,
                sessionGeneration == sessionRequest
            else {
                return
            }
            sessionMessage = error.localizedDescription
        }

        do {
            let loadedUsage = try await usageService.scan(
                range: range,
                accountID: accountID,
                force: force
            )
            guard refreshGeneration == generation else { return }
            if usageGeneration == usageRequest {
                usage = loadedUsage
                usageMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == generation else { return }
            if usageGeneration == usageRequest {
                usageMessage = error.localizedDescription
                if force {
                    present(error, title: "用量读取失败")
                }
            }
        }

        do {
            let loadedQuota = try await usageService.fetchQuota()
            guard refreshGeneration == generation else { return }
            accounts.refreshCurrentAccount()
            if loadedQuota.sourceUserID == accounts.currentUserID {
                quota = loadedQuota
                quotaMessage = nil
                let attributed = await localCycleCredits(for: loadedQuota)
                guard refreshGeneration == generation else { return }
                locallyAttributedCycleCredits = attributed
            } else {
                quota = nil
                locallyAttributedCycleCredits = nil
                quotaMessage = "账号已变更，旧额度结果已丢弃。"
            }
        } catch {
            guard refreshGeneration == generation else { return }
            quota = nil
            locallyAttributedCycleCredits = nil
            quotaMessage = error.localizedDescription
        }
    }

    func recalculateUsage() async {
        if let variant = selectedTraeVariant {
            await refreshTraeUsage(variant: variant, includeQuota: false)
            return
        }

        while isRefreshing || isUsageRefreshing {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }

        usageGeneration &+= 1
        let request = usageGeneration
        let range = usageDateRange
        let accountID = usageAccountID
        do {
            let recalculated = try await usageService.aggregateCached(
                range: range,
                accountID: accountID
            )
            guard !Task.isCancelled, usageGeneration == request else { return }
            usage = recalculated
            usageMessage = nil
        } catch {
            guard !Task.isCancelled, usageGeneration == request else { return }
            usageMessage = error.localizedDescription
        }
    }

    func refreshUsageIfIdle(force: Bool = false) async {
        if let variant = selectedTraeVariant {
            await refreshTraeUsage(
                variant: variant,
                includeQuota: force
            )
            return
        }

        guard !isRefreshing, !isUsageRefreshing else { return }
        isUsageRefreshing = true
        usageGeneration &+= 1
        let request = usageGeneration
        let range = usageDateRange
        let accountID = usageAccountID
        defer { isUsageRefreshing = false }

        do {
            let refreshed = try await usageService.scan(
                range: range,
                accountID: accountID,
                force: force
            )
            guard !Task.isCancelled, usageGeneration == request else { return }
            usage = refreshed
            usageMessage = nil
            if let quota, quota.sourceUserID == accounts.currentUserID {
                let attributed = await localCycleCredits(for: quota)
                guard !Task.isCancelled, usageGeneration == request else { return }
                locallyAttributedCycleCredits = attributed
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, usageGeneration == request else { return }
            usageMessage = error.localizedDescription
        }
    }

    func selectUsagePeriod(_ period: UsagePeriod) {
        usagePeriod = period
        guard period != .all, period != .custom else { return }

        let calendar = Calendar.current
        let now = Date()
        let range = period.dateRange(
            customStart: usageStartDate,
            customEnd: usageEndDate,
            now: now,
            calendar: calendar
        )
        if let start = range.startInclusive {
            usageStartDate = start
        }
        if let end = range.endExclusive,
           let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) {
            usageEndDate = inclusiveEnd
        }
    }

    func setUsageStartDate(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        usageStartDate = day
        if usageEndDate < day {
            usageEndDate = day
        }
        usagePeriod = .custom
    }

    func setUsageEndDate(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        usageEndDate = day
        if usageStartDate > day {
            usageStartDate = day
        }
        usagePeriod = .custom
    }

    func captureCurrentAccount() {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        do {
            if let variant = selectedTraeVariant {
                _ = try traeAccounts.captureCurrent(variant)
            } else {
                _ = try accounts.captureCurrent()
            }
            alert = AppAlert(
                title: "账号已保存",
                message: "\(selectedProvider.title) 登录快照已安全存入 macOS 钥匙串。"
            )
        } catch {
            present(error, title: "无法保存账号")
        }
    }

    func switchAccount(to profile: AccountProfile) async {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        guard resumingSessionID == nil else {
            alert = AppAlert(
                title: "正在准备对话",
                message: "对话迁移或恢复完成后再切换账号。"
            )
            return
        }
        invalidateRefreshResults()
        do {
            try await accounts.switchAccount(to: profile)
            usageAccountID = profile.id
            quota = nil
            locallyAttributedCycleCredits = nil
            quotaMessage = "正在刷新新账号额度。"
            try await Task.sleep(nanoseconds: 500_000_000)
            await refreshAll(force: true)
        } catch {
            present(error, title: "切换失败")
        }
    }

    func renameAccount(_ profile: AccountProfile, nickname: String) {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        do {
            try accounts.rename(profile, to: nickname)
        } catch {
            present(error, title: "重命名失败")
        }
    }

    func removeAccount(_ profile: AccountProfile) {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        do {
            try accounts.remove(profile)
            if usageAccountID == profile.id {
                usageAccountID = nil
                Task { await recalculateUsage() }
            }
        } catch {
            present(error, title: "移除失败")
        }
    }

    func switchTraeAccount(to profile: TraeAccountProfile) async {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        guard resumingSessionID == nil else {
            alert = AppAlert(
                title: "正在准备对话",
                message: "WorkBuddy 对话操作完成后再切换 Trae 账号。"
            )
            return
        }
        invalidateRefreshResults()
        do {
            try await traeAccounts.switchAccount(to: profile)
            usageAccountID = profile.userID
            quota = nil
            locallyAttributedCycleCredits = nil
            quotaMessage = "正在刷新新账号用量。"
            try await Task.sleep(nanoseconds: 500_000_000)
            await refreshAll(force: true)
        } catch {
            present(error, title: "切换失败")
        }
    }

    func renameTraeAccount(
        _ profile: TraeAccountProfile,
        nickname: String
    ) {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        do {
            try traeAccounts.rename(profile, to: nickname)
        } catch {
            present(error, title: "重命名失败")
        }
    }

    func removeTraeAccount(_ profile: TraeAccountProfile) {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        do {
            try traeAccounts.remove(profile)
            if usageAccountID == profile.userID,
               selectedTraeVariant == profile.variant {
                usageAccountID = nil
                Task { await recalculateUsage() }
            }
        } catch {
            present(error, title: "移除失败")
        }
    }

    // MARK: - 账号备份（导入 / 导出）

    var hasAnySavedAccount: Bool {
        !accounts.accounts.isEmpty || !traeAccounts.accounts.isEmpty
    }

    var canStartAccountBackup: Bool {
        !isAccountBackupBusy
            && !accounts.isSwitching
            && traeAccounts.switchingVariant == nil
            && resumingSessionID == nil
    }

    /// 导出全部账号到用户选择的 URL（加密文件）。
    func exportAllAccounts(to url: URL, password: String) async {
        guard canStartAccountBackup else {
            present(
                OpenUsageError.commandFailed("已有账号切换正在进行，请稍后再试。"),
                title: "操作被阻止"
            )
            return
        }
        isAccountBackupBusy = true
        defer { isAccountBackupBusy = false }
        do {
            let built = try accountBackup.buildExportPayload(
                workBuddy: accounts,
                traeAccounts: traeAccounts
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payloadJSON = try encoder.encode(built.payload)
            let sealed = try await Task.detached { () -> Data in
                try AccountBackupFile.encryptedFile(
                    payloadJSON: payloadJSON,
                    password: password
                )
            }.value
            try writeSecureBackupFile(sealed, to: url)
            var message = "已导出 \(built.summary.totalExported) 个账号到所选文件。"
            if built.summary.skippedWithoutSnapshot > 0 {
                message += "\n跳过 \(built.summary.skippedWithoutSnapshot) 个缺少凭据快照的账号，请重新登录并保存后再导出。"
            }
            alert = AppAlert(title: "导出完成", message: message)
        } catch let error as AccountBackupServiceError {
            alert = AppAlert(
                title: "无法导出",
                message: error.errorDescription ?? "当前没有可导出的账号。"
            )
        } catch {
            present(error, title: "导出失败")
        }
    }

    /// 从用户选择的备份文件导入账号。
    func importAccounts(from url: URL, password: String) async {
        guard canStartAccountBackup else {
            present(
                OpenUsageError.commandFailed("已有账号切换正在进行，请稍后再试。"),
                title: "操作被阻止"
            )
            return
        }
        isAccountBackupBusy = true
        defer { isAccountBackupBusy = false }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            try validateAccountBackupInput(byteCount: byteCount, accountCount: 0)
            let fileData = try Data(contentsOf: url)
            guard fileData.count <= AccountBackupInputLimits.maxFileBytes else {
                throw AccountBackupInputError.fileTooLarge(fileData.count)
            }
            let payloadJSON = try await Task.detached { () -> Data in
                try AccountBackupFile.decryptedPayload(
                    fileData: fileData,
                    password: password
                )
            }.value
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(BackupEnvelope.self, from: payloadJSON)
            guard
                envelope.format == BackupEnvelope.currentFormat,
                envelope.version == BackupEnvelope.currentVersion
            else {
                throw AccountBackupFileError.unsupportedVersion
            }
            try validateAccountBackupInput(
                byteCount: byteCount,
                accountCount: envelope.accounts.count
            )
            let summary = accountBackup.importFromEnvelope(
                envelope,
                workBuddy: accounts,
                traeAccounts: traeAccounts
            )
            var message = "成功导入 \(summary.imported) 个账号，跳过 \(summary.skipped) 个已存在账号。"
            if summary.failed > 0 {
                message += "\n失败 \(summary.failed) 个：" + summary.failures.map { "\n· \($0)" }.joined()
            }
            alert = AppAlert(
                title: summary.failed > 0 ? "导入完成（部分失败）" : "导入完成",
                message: message
            )
        } catch {
            present(error, title: "导入失败")
        }
    }

    func canResume(_ session: SessionRecord) -> Bool {
        guard
            !accounts.isSwitching,
            resumingSessionID == nil,
            let currentUserID = accounts.currentUserID
        else {
            return false
        }
        return !currentUserID.isEmpty
    }

    func sessionNeedsMigration(_ session: SessionRecord) -> Bool {
        guard let currentUserID = accounts.currentUserID else { return false }
        return session.userID != currentUserID
    }

    func resumeActionTitle(_ session: SessionRecord) -> String {
        switch (sessionNeedsMigration(session), session.isDeleted) {
        case (true, true):
            return "恢复、迁移并继续"
        case (true, false):
            return "迁移并继续"
        case (false, true):
            return "恢复并打开"
        case (false, false):
            return "继续对话"
        }
    }

    func resume(_ session: SessionRecord) async {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        guard beginResuming(session) else { return }
        defer { finishResuming(session) }

        var preparation: ResumePreparation?
        do {
            preparation = try await prepareToResume(session)
            try verifyCurrentAccount(preparation?.targetUserID)
            try await workBuddy.openSession(session.id)
            if let preparation, preparation.changedLocalState {
                await refreshAll(force: true)
            }
        } catch {
            let presentedError = await relaunchWorkBuddyIfNeeded(
                after: preparation,
                originalError: error
            )
            if let preparation, preparation.changedLocalState {
                await refreshAll(force: true)
            }
            let title = preparation?.changedLocalState == true
                ? "迁移已完成，打开失败"
                : "无法恢复对话"
            present(presentedError, title: title)
        }
    }

    func openInTerminal(_ session: SessionRecord) async {
        guard !isAccountBackupBusy else {
            present(OpenUsageError.commandFailed("账号备份或导入正在进行，请稍后再试。"), title: "操作被阻止")
            return
        }
        guard beginResuming(session) else { return }
        defer { finishResuming(session) }

        var preparation: ResumePreparation?
        do {
            try workBuddy.validateTerminalResume(session)
            preparation = try await prepareToResume(session)
            try verifyCurrentAccount(preparation?.targetUserID)
            try workBuddy.openSessionInTerminal(session)
            if preparation?.stoppedRunningApplication == true {
                try await workBuddy.launch()
            }
            if let preparation, preparation.changedLocalState {
                await refreshAll(force: true)
            }
        } catch {
            let presentedError = await relaunchWorkBuddyIfNeeded(
                after: preparation,
                originalError: error
            )
            if let preparation, preparation.changedLocalState {
                await refreshAll(force: true)
            }
            present(presentedError, title: "无法在终端恢复")
        }
    }

    func present(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    private struct ResumePreparation {
        let reassignedToCurrentAccount: Bool
        let restoredFromTrash: Bool
        let stoppedRunningApplication: Bool
        let targetUserID: String

        var changedLocalState: Bool {
            reassignedToCurrentAccount || restoredFromTrash
        }
    }

    private func prepareToResume(_ session: SessionRecord) async throws -> ResumePreparation {
        accounts.refreshCurrentAccount()
        guard
            let targetUserID = accounts.currentUserID,
            !targetUserID.isEmpty
        else {
            throw OpenUsageError.authenticationFileMissing
        }
        guard workBuddy.applicationURL != nil else {
            throw OpenUsageError.workBuddyNotInstalled
        }

        let needsMutation = session.userID != targetUserID || session.isDeleted
        guard needsMutation else {
            return ResumePreparation(
                reassignedToCurrentAccount: false,
                restoredFromTrash: false,
                stoppedRunningApplication: false,
                targetUserID: targetUserID
            )
        }

        invalidateRefreshResults()
        let wasRunning = workBuddy.isRunning
        do {
            try await workBuddy.stop()
            let verifiedUserID = try AuthDocument.loadActive().userID
            guard verifiedUserID == targetUserID else {
                accounts.refreshCurrentAccount()
                throw OpenUsageError.commandFailed(
                    "WorkBuddy 当前账号在准备恢复时发生变化，请重新选择对话。"
                )
            }

            let store = sessionStore
            let mutation = try await Task.detached(priority: .userInitiated) {
                try store.prepareSessionForResume(
                    sessionID: session.id,
                    expectedSourceUserID: session.userID,
                    targetUserID: targetUserID,
                    restoreFromTrash: session.isDeleted
                )
            }.value
            return ResumePreparation(
                reassignedToCurrentAccount: mutation.reassignedToCurrentAccount,
                restoredFromTrash: mutation.restoredFromTrash,
                stoppedRunningApplication: wasRunning,
                targetUserID: targetUserID
            )
        } catch {
            let preparationError = error
            await reloadSessions()
            if wasRunning {
                do {
                    try await workBuddy.launch()
                } catch {
                    throw OpenUsageError.commandFailed(
                        """
                        \(preparationError.localizedDescription)
                        WorkBuddy 重新启动失败：\(error.localizedDescription)
                        """
                    )
                }
            }
            throw preparationError
        }
    }

    private func beginResuming(_ session: SessionRecord) -> Bool {
        guard resumingSessionID == nil, !accounts.isSwitching else { return false }
        resumingSessionID = session.id
        return true
    }

    private func finishResuming(_ session: SessionRecord) {
        if resumingSessionID == session.id {
            resumingSessionID = nil
        }
    }

    private func verifyCurrentAccount(_ expectedUserID: String?) throws {
        guard let expectedUserID else { throw OpenUsageError.authenticationFileMissing }
        let currentUserID = try AuthDocument.loadActive().userID
        guard currentUserID == expectedUserID else {
            accounts.refreshCurrentAccount()
            throw OpenUsageError.commandFailed(
                "WorkBuddy 当前账号在打开对话前发生变化，已停止自动打开。"
            )
        }
    }

    private func relaunchWorkBuddyIfNeeded(
        after preparation: ResumePreparation?,
        originalError: Error
    ) async -> Error {
        guard
            preparation?.stoppedRunningApplication == true,
            !workBuddy.isRunning
        else {
            return originalError
        }
        do {
            try await workBuddy.launch()
            return originalError
        } catch {
            return OpenUsageError.commandFailed(
                """
                \(originalError.localizedDescription)
                WorkBuddy 重新启动失败：\(error.localizedDescription)
                """
            )
        }
    }

    private func refreshTraeAll(
        variant: TraeVariant,
        force: Bool
    ) async {
        refreshGeneration &+= 1
        usageGeneration &+= 1
        let generation = refreshGeneration
        let usageRequest = usageGeneration
        let provider = variant.provider
        let range = usageDateRange
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }

        traeAccounts.refreshCurrentAccounts()
        sessions = []
        sessionMessage = "\(provider.title) 暂不支持对话浏览或恢复。"
        if usageAccountID == nil {
            usageAccountID = traeAccounts.currentUserID(for: variant)
        }

        do {
            let report = try await loadTraeReport(
                variant: variant,
                range: range
            )
            guard
                refreshGeneration == generation,
                usageGeneration == usageRequest,
                selectedProvider == provider
            else {
                return
            }
            usage = report.usage
            traeQuota = report.quota
            quota = report.quota.quotaSnapshot
            locallyAttributedCycleCredits = nil
            usageMessage = nil
            quotaMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard
                refreshGeneration == generation,
                selectedProvider == provider
            else {
                return
            }
            usageMessage = error.localizedDescription
            quotaMessage = error.localizedDescription
            quota = nil
            traeQuota = nil
            locallyAttributedCycleCredits = nil
            if force {
                present(error, title: "\(provider.title) 用量读取失败")
            }
        }
    }

    private func refreshTraeUsage(
        variant: TraeVariant,
        includeQuota: Bool
    ) async {
        while isRefreshing || isUsageRefreshing {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }

        isUsageRefreshing = true
        usageGeneration &+= 1
        let request = usageGeneration
        let provider = variant.provider
        let range = usageDateRange
        defer { isUsageRefreshing = false }

        do {
            let refreshedUsage: UsageSnapshot
            let refreshedQuota: TraeQuotaSummary?
            if includeQuota {
                let report = try await loadTraeReport(
                    variant: variant,
                    range: range
                )
                refreshedUsage = report.usage
                refreshedQuota = report.quota
            } else {
                refreshedUsage = try await loadTraeUsage(
                    variant: variant,
                    range: range
                )
                refreshedQuota = nil
            }
            guard
                !Task.isCancelled,
                usageGeneration == request,
                selectedProvider == provider
            else {
                return
            }
            usage = refreshedUsage
            usageMessage = nil
            if let refreshedQuota {
                traeQuota = refreshedQuota
                quota = refreshedQuota.quotaSnapshot
                quotaMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard
                !Task.isCancelled,
                usageGeneration == request,
                selectedProvider == provider
            else {
                return
            }
            usageMessage = error.localizedDescription
            if includeQuota {
                quotaMessage = error.localizedDescription
            }
        }
    }

    private func loadTraeReport(
        variant: TraeVariant,
        range: UsageDateRange
    ) async throws -> TraeUsageReport {
        if let snapshot = try selectedTraeSnapshot(variant: variant) {
            return try await traeUsageService.fetchReport(
                snapshot: snapshot,
                range: range
            )
        }
        return try await traeUsageService.fetchReport(
            for: variant,
            range: range
        )
    }

    private func loadTraeUsage(
        variant: TraeVariant,
        range: UsageDateRange
    ) async throws -> UsageSnapshot {
        if let snapshot = try selectedTraeSnapshot(variant: variant) {
            return try await traeUsageService.fetchUsage(
                snapshot: snapshot,
                range: range
            )
        }
        return try await traeUsageService.fetchUsage(
            for: variant,
            range: range
        )
    }

    private func selectedTraeSnapshot(
        variant: TraeVariant
    ) throws -> TraeCredentialSnapshot? {
        guard let accountID = usageAccountID else { return nil }
        if traeAccounts.accounts(for: variant).contains(
            where: { $0.userID == accountID }
        ) {
            return try traeAccounts.snapshot(
                for: variant,
                userID: accountID
            )
        }
        if traeAccounts.currentUserID(for: variant) == accountID {
            return nil
        }
        throw TraeSupportError.accountSnapshotMissing
    }

    private func reloadSessions() async {
        sessionGeneration &+= 1
        let request = sessionGeneration
        do {
            let store = sessionStore
            let loadedSessions = try await Task.detached(priority: .utility) {
                try store.loadSessions(includeDeleted: true)
            }.value
            guard sessionGeneration == request else { return }
            sessions = loadedSessions
            sessionMessage = nil
        } catch {
            guard sessionGeneration == request else { return }
            sessionMessage = error.localizedDescription
        }
    }

    private func invalidateRefreshResults() {
        refreshGeneration &+= 1
        usageGeneration &+= 1
        isRefreshing = false
    }

    /// 备份文件安全写入：同目录临时文件 0600 创建 → 权限确认 → 原子替换作为最后一步。
    private func writeSecureBackupFile(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".openusage-backup-\(UUID().uuidString).tmp"
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw OpenUsageError.commandFailed("无法写入备份文件，请检查目标位置权限。")
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            // commit-last：替换/移动作为最后一个可能失败的步骤。
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(
                    url,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func localCycleCredits(for quota: QuotaSnapshot) async -> Double? {
        guard let cycleStartsAt = quota.cycleStartsAt else { return nil }
        let endExclusive = quota.resetsAt?.addingTimeInterval(1)
        let snapshot = try? await usageService.aggregateCached(
            range: UsageDateRange(
                startInclusive: cycleStartsAt,
                endExclusive: endExclusive
            ),
            accountID: quota.sourceUserID
        )
        return snapshot?.credits
    }

    private func localRefreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if let variant = selectedTraeVariant {
                guard
                    !isRefreshing,
                    !traeAccounts.isSwitching(variant)
                else {
                    continue
                }
                traeAccounts.refreshCurrentAccounts()
                await refreshUsageIfIdle()
            } else {
                guard
                    !isRefreshing,
                    !accounts.isSwitching,
                    resumingSessionID == nil
                else {
                    continue
                }
                await reloadSessions()
                await refreshUsageIfIdle()
            }
        }
    }

    private func autoRefreshLoop() async {
        while !Task.isCancelled {
            let configured = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
            let minutes = configured > 0 ? configured : 10
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            if !Task.isCancelled {
                await refreshAll()
            }
        }
    }
}
