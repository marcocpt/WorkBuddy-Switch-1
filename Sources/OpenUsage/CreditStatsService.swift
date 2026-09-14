import Foundation

// MARK: - 服务层输入（只含读权限所需的最小凭据载体）

/// 资源聚合结果（卡片级数值）。
struct WorkBuddyCreditSummary: Hashable, Sendable {
    let totalRemaining: Double
    let expiringSoonRemaining: Double
    let soonestExpireAt: Date?
}

/// WorkBuddy 账号积分查询输入：账号身份 + 原样凭据字节。
struct WorkBuddyCreditAccount: Sendable {
    let userID: String
    let accountID: String
    let accountName: String
    let isCurrent: Bool
    let authData: Data
}

/// Trae 账号积分查询输入：变体 + 快照。
struct TraeCreditAccount: Sendable {
    let variant: TraeVariant
    let profileID: String
    let userID: String
    let accountName: String
    let isCurrent: Bool
    let snapshot: TraeCredentialSnapshot
}

// MARK: - 服务

/// 逐账号并行拉取积分统计；单账号失败隔离为错误卡片，不阻塞其余账号。
actor CreditStatsService {
    private let httpClient: any CreditStatsHTTPClient
    private let traeUsageService: TraeUsageService
    private let maxConcurrency: Int
    private let timeoutInterval: TimeInterval
    private let workBuddyEndpoint: URL

    init(
        httpClient: any CreditStatsHTTPClient = URLSessionCreditStatsHTTPClient(),
        traeUsageService: TraeUsageService = TraeUsageService(),
        maxConcurrency: Int = 4,
        timeoutInterval: TimeInterval = 12,
        workBuddyEndpoint: URL = URL(
            string: "https://www.codebuddy.cn/v2/billing/meter/get-user-resource"
        )!
    ) {
        self.httpClient = httpClient
        self.traeUsageService = traeUsageService
        self.maxConcurrency = max(1, maxConcurrency)
        self.timeoutInterval = max(1, timeoutInterval)
        self.workBuddyEndpoint = workBuddyEndpoint
    }

    /// 汇总三端账号的积分统计；不抛整体错误（故障都落在卡片上）。
    func refresh(
        workBuddy: [WorkBuddyCreditAccount],
        trae: [TraeCreditAccount],
        now: Date = Date()
    ) async -> [AccountCreditStat] {
        var inputs: [(provider: ManagedProvider, fetch: @Sendable () async -> AccountCreditStat)] = []
        inputs.append(contentsOf: workBuddy.map { account in
            (
                .workBuddy,
                { @Sendable [self] in await self.fetchWorkBuddy(account, now: now) }
            )
        })
        inputs.append(contentsOf: trae.map { account in
            (
                account.variant.provider,
                { @Sendable [self] in await self.fetchTrae(account, now: now) }
            )
        })

        var stats: [AccountCreditStat] = []
        var offset = 0
        while offset < inputs.count {
            let upper = min(offset + maxConcurrency, inputs.count)
            let batch = Array(inputs[offset..<upper])
            let results = await withTaskGroup(
                of: (Int, AccountCreditStat).self
            ) { group in
                for (batchOffset, input) in batch.enumerated() {
                    let fetch = input.fetch
                    group.addTask {
                        (batchOffset, await fetch())
                    }
                }
                var collected: [Int: AccountCreditStat] = [:]
                for await item in group {
                    collected[item.0] = item.1
                }
                return batch.indices.compactMap { collected[$0] }
            }
            stats.append(contentsOf: results)
            offset += maxConcurrency
        }
        return CreditStatMapper.sort(stats)
    }

    // MARK: - WorkBuddy

    private func fetchWorkBuddy(
        _ account: WorkBuddyCreditAccount,
        now: Date
    ) async -> AccountCreditStat {
        do {
            let document = try AuthDocument(data: account.authData)
            // 凭据身份必须与卡片身份一致，防止错绑 token 把别的账号数据标到本卡
            guard document.userID == account.userID else {
                throw WorkBuddyCreditError.identityMismatch
            }
            let token = try document.accessToken()
            let resources = try await fetchWorkBuddyResources(
                token: token,
                now: now
            )
            let summary = WorkBuddyCreditParser.summarize(resources, now: now)
            let packages = WorkBuddyCreditParser.packages(from: resources)
            return baseStat(
                provider: .workBuddy,
                accountID: account.accountID,
                accountName: account.accountName,
                isCurrent: account.isCurrent,
                sourceUserID: account.userID
            ).resolving(
                totalRemaining: summary.totalRemaining,
                expiringSoonRemaining: summary.expiringSoonRemaining,
                soonestExpireAt: summary.soonestExpireAt,
                unit: .credits,
                packages: packages,
                refreshDate: now
            )
        } catch let error as WorkBuddyCreditError {
            return workBuddyFailure(account, message: error.message)
        } catch {
            return workBuddyFailure(account, message: error.localizedDescription)
        }
    }

    private func fetchWorkBuddyResources(
        token: String,
        now: Date
    ) async throws -> [CreditResource] {
        // fail-closed：即使注入任意端点也不得发往非官方主机
        try WorkBuddyOfficialHostPolicy.validateRequest(workBuddyEndpoint)
        var request = URLRequest(url: workBuddyEndpoint, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WorkBuddy", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw WorkBuddyCreditError.expired
        }
        guard response.statusCode == 200 else {
            throw WorkBuddyCreditError.unavailable
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw WorkBuddyCreditError.unavailable
        }
        guard WorkBuddyCreditParser.hasAccounts(in: root) else {
            throw WorkBuddyCreditError.unavailable
        }
        let accountRecords = WorkBuddyCreditParser.accounts(in: root)
        // 空 Accounts 是合法成功（0 积分）；有记录但整体无法解析出任何容量数值 → 格式失败
        if accountRecords.isEmpty {
            return []
        }
        guard
            accountRecords.contains(where: WorkBuddyCreditParser.hasParsableCapacityFields)
        else {
            throw WorkBuddyCreditError.unavailable
        }
        return accountRecords.map {
            WorkBuddyCreditParser.resource(from: $0, now: now)
        }
    }

    // MARK: - Trae

    private func fetchTrae(
        _ account: TraeCreditAccount,
        now: Date
    ) async -> AccountCreditStat {
        do {
            let quota = try await traeUsageService.fetchQuota(
                snapshot: account.snapshot
            )
            return CreditStatMapper.statForTraeQuota(
                variant: account.variant,
                accountID: account.profileID,
                accountName: account.accountName,
                isCurrent: account.isCurrent,
                sourceUserID: account.userID,
                quota: quota,
                now: now
            )
        } catch TraeSupportError.authenticationExpired {
            return traeFailure(account, message: "登录已过期，请刷新登录后重试")
        } catch {
            return traeFailure(account, message: error.localizedDescription)
        }
    }

    // MARK: - 卡片装配

    private func baseStat(
        provider: ManagedProvider,
        accountID: String,
        accountName: String,
        isCurrent: Bool,
        sourceUserID: String
    ) -> AccountCreditStat {
        AccountCreditStat(
            provider: provider,
            accountID: accountID,
            accountName: accountName,
            isCurrent: isCurrent,
            unit: provider == .workBuddy ? .credits : .credits,
            totalRemaining: nil,
            expiringSoonRemaining: 0,
            soonestExpireAt: nil,
            error: nil,
            sourceUserID: sourceUserID,
            refreshDate: nil
        )
    }

    private func workBuddyFailure(
        _ account: WorkBuddyCreditAccount,
        message: String
    ) -> AccountCreditStat {
        .failure(
            provider: .workBuddy,
            accountID: account.accountID,
            accountName: account.accountName,
            isCurrent: account.isCurrent,
            sourceUserID: account.userID,
            error: message
        )
    }

    private func traeFailure(
        _ account: TraeCreditAccount,
        message: String
    ) -> AccountCreditStat {
        .failure(
            provider: account.variant.provider,
            accountID: account.profileID,
            accountName: account.accountName,
            isCurrent: account.isCurrent,
            sourceUserID: account.userID,
            error: message
        )
    }
}

// MARK: - Trae 额度 → 卡片映射 + 排序

enum CreditStatMapper {
    /// Trae 额度模型 → 卡片。Credits/请求单位决定主数值；下次结算日为过期展示。
    static func statForTraeQuota( // swiftlint:disable:this function_parameter_count
        variant: TraeVariant,
        accountID: String,
        accountName: String,
        isCurrent: Bool,
        sourceUserID: String,
        quota: TraeQuotaSummary,
        now: Date = Date()
    ) -> AccountCreditStat {
        let unit: CreditUsageUnit = quota.isUnlimited ? .unlimited : (quota.unit == .credits ? .credits : .requests)
        let remaining = quota.total.map { max($0 - quota.used, 0) }
        let soonest = quota.resetsAt
        let expiringSoon: Double
        if let soonest {
            let near = soonest > now && soonest <= now.addingTimeInterval(CreditStatsRules.expiringSoonDays)
            expiringSoon = near ? (remaining ?? 0) : 0
        } else {
            expiringSoon = 0
        }
        let packages = quota.packs.map { pack in
            let packRemaining = pack.limit.map { max($0 - pack.used, 0) } ?? 0
            let expireAt = pack.expireAt
            return CreditPackage(
                name: pack.name,
                total: pack.limit,
                remaining: packRemaining,
                used: pack.used,
                expireAt: expireAt,
                expired: packRemaining > 0
                    && (expireAt.map { $0 <= now } ?? false),
                expiringSoon: packRemaining > 0
                    && (expireAt.map {
                        now < $0 && $0 <= now.addingTimeInterval(CreditStatsRules.expiringSoonDays)
                    } ?? false)
            )
        }
        return AccountCreditStat(
            provider: variant.provider,
            accountID: accountID,
            accountName: accountName,
            isCurrent: isCurrent,
            unit: unit,
            totalRemaining: remaining,
            expiringSoonRemaining: expiringSoon,
            soonestExpireAt: soonest,
            error: nil,
            sourceUserID: sourceUserID,
            packages: packages,
            refreshDate: now
        )
    }

    /// 卡片排序/分组用的「最近到期」：优先取该卡片里最早的一个「仍有剩余且未到期」的积分包到期日；
    /// 没有这类带日期的包时，才回落到卡片自身的到期/结算日（Trae 的下次结算日即走此回落）。
    static func orderingExpiry(_ stat: AccountCreditStat) -> Date? {
        let earliestLivePackage = stat.packages
            .filter { $0.remaining > 0 && !$0.expired }
            .compactMap(\.expireAt)
            .min()
        return earliestLivePackage ?? stat.soonestExpireAt
    }

    /// 稳定排序：WorkBuddy → Trae CN → TRAE Work；
    /// 组内按「最近到期日」升序（最快到期在最前），无到期日的卡片次之，拉取失败的卡片最后；
    /// 同级保持输入顺序。
    static func sort(_ stats: [AccountCreditStat]) -> [AccountCreditStat] {
        stats.enumerated().sorted { lhs, rhs in
            let leftRank = providerRank(lhs.element.provider)
            let rightRank = providerRank(rhs.element.provider)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftBucket = cardBucket(lhs.element)
            let rightBucket = cardBucket(rhs.element)
            if leftBucket != rightBucket { return leftBucket < rightBucket }
            switch (orderingExpiry(lhs.element), orderingExpiry(rhs.element)) {
            case let (left?, right?):
                if left != right { return left < right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 每个 app 一列；没有卡片的 app 不产生空列。列内沿用 sort 的到期顺序。
    static func columns(_ stats: [AccountCreditStat]) -> [CreditStatColumn] {
        let sorted = sort(stats)
        return ManagedProvider.allCases.compactMap { provider in
            let items = sorted.filter { $0.provider == provider }
            guard !items.isEmpty else { return nil }
            return CreditStatColumn(provider: provider, stats: items)
        }
    }

    /// 卡片分组：有到期日 → 无到期日 → 拉取失败。
    private static func cardBucket(_ stat: AccountCreditStat) -> Int {
        if stat.error != nil { return 2 }
        return orderingExpiry(stat) == nil ? 1 : 0
    }

    private static func providerRank(_ provider: ManagedProvider) -> Int {
        switch provider {
        case .workBuddy: return 0
        case .traeCN: return 1
        case .traeWork: return 2
        }
    }
}

enum WorkBuddyCreditError: Error {
    case expired
    case unavailable
    case unsafeHost
    case identityMismatch

    var message: String {
        switch self {
        case .expired:
            return "登录已过期，请刷新登录后重试"
        case .unavailable:
            return "积分查询失败"
        case .unsafeHost:
            return "积分服务地址不受信任，已停止请求"
        case .identityMismatch:
            return "凭据身份与账号不匹配，请重新登录并保存"
        }
    }
}
