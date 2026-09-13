import Foundation

/// 备份账号所属客户端（三端）。
enum BackupProvider: String, Codable, Sendable {
    case workBuddy
    case traeCN
    case traeWork

    var title: String {
        switch self {
        case .workBuddy: return "WorkBuddy"
        case .traeCN: return "Trae CN"
        case .traeWork: return "TRAE Work"
        }
    }
}

/// 备份记录中的账号元数据（导入时与既有索引合并，见 §4 冲突决策）。
struct BackupAccountMetadata: Codable, Equatable, Sendable {
    var accountID: String
    var nickname: String
    var accountType: String?
    var phoneHint: String?
    var email: String?
    var avatarURL: String?
    var capturedAt: Date
    var lastUsedAt: Date

    init(
        accountID: String,
        nickname: String,
        accountType: String? = nil,
        phoneHint: String? = nil,
        email: String? = nil,
        avatarURL: String? = nil,
        capturedAt: Date,
        lastUsedAt: Date
    ) {
        self.accountID = accountID
        self.nickname = nickname
        self.accountType = accountType
        self.phoneHint = phoneHint
        self.email = email
        self.avatarURL = avatarURL
        self.capturedAt = capturedAt
        self.lastUsedAt = lastUsedAt
    }

    init(workBuddy profile: AccountProfile) {
        self.init(
            accountID: profile.id,
            nickname: profile.nickname,
            accountType: profile.accountType,
            phoneHint: profile.phoneHint,
            capturedAt: profile.capturedAt,
            lastUsedAt: profile.lastUsedAt
        )
    }

    init(trae profile: TraeAccountProfile) {
        self.init(
            accountID: profile.userID,
            nickname: profile.nickname,
            email: profile.email,
            avatarURL: profile.avatarURL,
            capturedAt: profile.capturedAt,
            lastUsedAt: profile.lastUsedAt
        )
    }

    func accountProfile() -> AccountProfile {
        AccountProfile(
            id: accountID,
            nickname: nickname,
            accountType: accountType,
            phoneHint: phoneHint,
            capturedAt: capturedAt,
            lastUsedAt: lastUsedAt
        )
    }

    func traeProfile(variant: TraeVariant) -> TraeAccountProfile {
        TraeAccountProfile(
            variant: variant,
            userID: accountID,
            nickname: nickname,
            email: email,
            avatarURL: avatarURL,
            capturedAt: capturedAt,
            lastUsedAt: lastUsedAt
        )
    }
}

/// 凭据镜像：WorkBuddy 为 AuthDocument 原始字节（不透明），Trae 直接复用既有快照编码。
enum BackupCredential: Codable, Equatable, Sendable {
    case workBuddy(Data)
    case trae(TraeCredentialSnapshot)

    private enum Kind: String, Codable {
        case workBuddy
        case trae
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case workBuddyBlob
        case traeSnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .workBuddy:
            let encoded = try container.decode(String.self, forKey: .workBuddyBlob)
            guard let data = Data(base64Encoded: encoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .workBuddyBlob,
                    in: container,
                    debugDescription: "invalid base64 payload"
                )
            }
            self = .workBuddy(data)
        case .trae:
            self = .trae(try container.decode(TraeCredentialSnapshot.self, forKey: .traeSnapshot))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workBuddy(let data):
            try container.encode(Kind.workBuddy, forKey: .kind)
            try container.encode(data.base64EncodedString(), forKey: .workBuddyBlob)
        case .trae(let snapshot):
            try container.encode(Kind.trae, forKey: .kind)
            try container.encode(snapshot, forKey: .traeSnapshot)
        }
    }

    /// 提取 Trae 快照（记录已通过身份预校验时保证存在）。
    func traeSnapshot() throws -> TraeCredentialSnapshot {
        guard case .trae(let snapshot) = self else {
            throw BackupLoadError.invalidCredential
        }
        return snapshot
    }
}

/// 单个账号的备份记录：客户端标识 + 元数据 + 凭据镜像。
struct BackupAccountRecord: Codable, Equatable, Sendable {
    var provider: BackupProvider
    var metadata: BackupAccountMetadata
    var credential: BackupCredential
}

/// 备份包容器（加密前的明文载荷）。
struct BackupEnvelope: Codable, Equatable, Sendable {
    static let currentFormat = "workbuddy-switch-accounts"
    static let currentVersion = 1

    var format: String
    var version: Int
    var exportedAt: Date
    var accounts: [BackupAccountRecord]
}

/// 记录级校验失败原因。
enum BackupLoadError: Error, Equatable, Sendable {
    case identityMismatch
    case invalidCredential
}

/// 备份提供方 → Trae 变体映射（WorkBuddy 无变体）。
func traeVariant(for provider: BackupProvider) -> TraeVariant? {
    switch provider {
    case .workBuddy: return nil
    case .traeCN: return .china
    case .traeWork: return .work
    }
}

/// Trae 变体 → 备份提供方映射。
func backupProvider(for variant: TraeVariant) -> BackupProvider {
    switch variant {
    case .china: return .traeCN
    case .work: return .traeWork
    }
}

/// 校验记录「凭据身份 ↔ 元数据身份」一致性；返回 nil 表示有效。
///
/// Trae 记录会解析凭据内嵌身份（authBlob 中的真实 userID），要求其与快照字段、
/// 元数据三者一致；各 provider 与凭据类型必须匹配，杜绝非法组合。
func validateBackupRecord(_ record: BackupAccountRecord) -> BackupLoadError? {
    switch record.credential {
    case .workBuddy(let blob):
        guard record.provider == .workBuddy else { return .identityMismatch }
        let embeddedUserID: String
        do {
            embeddedUserID = try AuthDocument(data: blob).userID
        } catch {
            return .invalidCredential
        }
        return embeddedUserID == record.metadata.accountID
            ? nil
            : .identityMismatch
    case .trae(let snapshot):
        guard traeVariant(for: record.provider) == snapshot.variant else {
            return .identityMismatch
        }
        guard let payload = try? TraeStorageCodec.authPayload(from: snapshot.authBlob) else {
            return .invalidCredential
        }
        guard
            payload.userID == snapshot.userID,
            snapshot.userID == record.metadata.accountID
        else {
            return .identityMismatch
        }
        return nil
    }
}

/// 导入决策：目标钥匙串已存在同一账号快照时跳过，不覆盖任何数据。
enum BackupImportAction: Equatable, Sendable {
    case skip
    case apply
}

func backupImportAction(vaultHasRecord: Bool) -> BackupImportAction {
    vaultHasRecord ? .skip : .apply
}

/// 索引合并：存在则保留本机既有元数据（如自定义昵称），缺失则追加导入值。
func mergeIndexMetadata(
    existing: BackupAccountMetadata?,
    imported: BackupAccountMetadata
) -> BackupAccountMetadata {
    existing ?? imported
}
