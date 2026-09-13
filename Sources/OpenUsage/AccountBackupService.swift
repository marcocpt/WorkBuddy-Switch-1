import Foundation

struct BackupExportSummary: Equatable, Sendable {
    var totalExported: Int = 0
    var skippedWithoutSnapshot: Int = 0
}

struct BackupImportSummary: Equatable, Sendable {
    var imported: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var failures: [String] = []
}

/// 导入应用结果，供上层精确计数（TOCTOU 下已存在应计入跳过而非导入）。
enum BackupImportApplyResult: Equatable, Sendable {
    case inserted
    case alreadyExists
}

enum AccountBackupServiceError: LocalizedError, Equatable, Sendable {
    case emptyExport
    case unsupportedBackup(String)

    var errorDescription: String? {
        switch self {
        case .emptyExport:
            return "当前没有已保存的账号，请先在各客户端登录并保存账号。"
        case .unsupportedBackup(let message):
            return message
        }
    }
}

enum AccountBackupInputError: LocalizedError, Equatable, Sendable {
    case fileTooLarge(Int)
    case tooManyAccounts(Int)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size):
            return "备份文件过大（\(size) 字节），已超过可导入上限。"
        case .tooManyAccounts(let count):
            return "备份包含过多账号（\(count) 个），已超过可导入上限。"
        }
    }
}

/// 本地上限：防止超大/恶意文件在解密或解析前消耗过多内存（NFR-3 仅要求数百账号规模）。
enum AccountBackupInputLimits {
    static let maxFileBytes = 64 * 1024 * 1024
    static let maxAccounts = 1000
}

/// 纯输入规模校验（任何解密/反序列化之前调用）。
func validateAccountBackupInput(byteCount: Int, accountCount: Int) throws {
    guard byteCount <= AccountBackupInputLimits.maxFileBytes else {
        throw AccountBackupInputError.fileTooLarge(byteCount)
    }
    guard accountCount <= AccountBackupInputLimits.maxAccounts else {
        throw AccountBackupInputError.tooManyAccounts(accountCount)
    }
}

/// 备份编排的纯核心：与具体仓库/钥匙串解耦，便于离线自测。
enum AccountBackupCore {
    /// 从仓库条目构造备份包；索引有但凭据缺失/身份不合法的条目计入 skipped，不中断。
    static func exportEnvelope(
        workBuddyItems: [(profile: AccountProfile, blob: Data?)],
        traeItems: [(profile: TraeAccountProfile, snapshot: TraeCredentialSnapshot?)],
        exportedAt: Date = Date()
    ) throws -> (envelope: BackupEnvelope, summary: BackupExportSummary) {
        var records: [BackupAccountRecord] = []
        var skipped = 0

        for (profile, blob) in workBuddyItems {
            guard let blob else {
                skipped += 1
                continue
            }
            let record = BackupAccountRecord(
                provider: .workBuddy,
                metadata: BackupAccountMetadata(workBuddy: profile),
                credential: .workBuddy(blob)
            )
            guard validateBackupRecord(record) == nil else {
                skipped += 1
                continue
            }
            records.append(record)
        }

        for (profile, snapshot) in traeItems {
            guard let snapshot else {
                skipped += 1
                continue
            }
            let record = BackupAccountRecord(
                provider: backupProvider(for: profile.variant),
                metadata: BackupAccountMetadata(trae: profile),
                credential: .trae(snapshot)
            )
            guard validateBackupRecord(record) == nil else {
                skipped += 1
                continue
            }
            records.append(record)
        }

        guard !records.isEmpty else {
            throw AccountBackupServiceError.emptyExport
        }

        let envelope = BackupEnvelope(
            format: BackupEnvelope.currentFormat,
            version: BackupEnvelope.currentVersion,
            exportedAt: exportedAt,
            accounts: records
        )
        return (
            envelope,
            BackupExportSummary(
                totalExported: records.count,
                skippedWithoutSnapshot: skipped
            )
        )
    }

    /// 两遍流程：第一遍全量预校验（非法记录进入失败），第二遍只对有效记录做
    /// 存在性判定与应用。存在性探测抛错（钥匙串故障）时该记录计入失败，绝不写入。
    static func importSummary(
        records: [BackupAccountRecord],
        vaultStatus: (BackupAccountRecord) throws -> Bool,
        applyRecord: (BackupAccountRecord) throws -> BackupImportApplyResult
    ) -> BackupImportSummary {
        var summary = BackupImportSummary()
        var actionable: [BackupAccountRecord] = []

        for record in records {
            guard validateBackupRecord(record) == nil else {
                summary.failed += 1
                summary.failures.append(
                    "\(record.provider.title) · \(record.metadata.nickname)：凭据身份与账号不一致，已忽略。"
                )
                continue
            }
            actionable.append(record)
        }

        for record in actionable {
            let exists: Bool
            do {
                exists = try vaultStatus(record)
            } catch {
                summary.failed += 1
                summary.failures.append(
                    "\(record.provider.title) · \(record.metadata.nickname)：读取钥匙串状态失败，已跳过。"
                )
                continue
            }
            if exists {
                summary.skipped += 1
                continue
            }
            do {
                switch try applyRecord(record) {
                case .inserted:
                    summary.imported += 1
                case .alreadyExists:
                    summary.skipped += 1
                }
            } catch {
                summary.failed += 1
                summary.failures.append(
                    "\(record.provider.title) · \(record.metadata.nickname)：\(error.localizedDescription)"
                )
            }
        }
        return summary
    }
}

/// 编排服务：组合两个账号仓库执行导出/导入，暴露进行中状态。
@MainActor
final class AccountBackupService: ObservableObject {
    @Published private(set) var isBusy = false

    func buildExportPayload(
        workBuddy: AccountStore,
        traeAccounts: TraeAccountStore
    ) throws -> (payload: BackupEnvelope, summary: BackupExportSummary) {
        isBusy = true
        defer { isBusy = false }
        let result = try AccountBackupCore.exportEnvelope(
            workBuddyItems: workBuddy.backupExportItems(),
            traeItems: traeAccounts.backupExportItems()
        )
        return (result.envelope, result.summary)
    }

    func importFromEnvelope(
        _ envelope: BackupEnvelope,
        workBuddy: AccountStore,
        traeAccounts: TraeAccountStore
    ) -> BackupImportSummary {
        isBusy = true
        defer { isBusy = false }
        return AccountBackupCore.importSummary(
            records: envelope.accounts,
            vaultStatus: { record in
                switch record.credential {
                case .workBuddy:
                    return try workBuddy.snapshotPresence(for: record.metadata.accountID)
                case .trae(let snapshot):
                    return try traeAccounts.hasSnapshot(
                        variant: snapshot.variant,
                        userID: record.metadata.accountID
                    )
                }
            },
            applyRecord: { record in
                switch record.credential {
                case .workBuddy(let blob):
                    return try workBuddy.importSnapshot(
                        profile: record.metadata.accountProfile(),
                        blob: blob
                    )
                case .trae(let snapshot):
                    return try traeAccounts.importSnapshot(
                        profile: record.metadata.traeProfile(variant: snapshot.variant),
                        snapshot: snapshot
                    )
                }
            }
        )
    }
}
