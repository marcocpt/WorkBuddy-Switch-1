import Foundation

// MARK: - Models

enum CreditUsageUnit: String, Hashable, Sendable {
    case credits
    case requests
    case unlimited
}

/// 单个资源包（WorkBuddy billing 接口的资源粒度）。
struct CreditResource: Hashable, Sendable {
    var packageCode: String?
    var packageName: String?
    var total: Double
    var remaining: Double
    var used: Double
    var status: Int?
    var expireAt: Date?
    var expired: Bool
    var expiringSoon: Bool
}

/// 单个积分/权益包的展示明细（WorkBuddy 资源包 或 Trae 权益包）。
struct CreditPackage: Hashable, Sendable {
    let name: String
    /// nil = 不限量（Trae 权益包透支负 limit 的口径）
    let total: Double?
    let remaining: Double
    let used: Double
    let expireAt: Date?
    let expired: Bool
    let expiringSoon: Bool

    var isUnlimited: Bool { total == nil }
}

/// 单个已保存账号的积分统计视图模型（不含任何凭据字段）。
struct AccountCreditStat: Identifiable, Hashable, Sendable {
    let provider: ManagedProvider
    /// WorkBuddy：userID；Trae：variant:userID
    let accountID: String
    let accountName: String
    let isCurrent: Bool
    let unit: CreditUsageUnit
    /// 总积分（剩余）；unlimited / 不可知时为 nil
    let totalRemaining: Double?
    let expiringSoonRemaining: Double
    let soonestExpireAt: Date?
    let error: String?
    /// 用于刷新竞态绑定身份的账号真实 userID
    let sourceUserID: String
    /// 全部积分包明细（WorkBuddy 资源包 / Trae 权益包）；未取到为空
    var packages: [CreditPackage] = []
    /// 本轮刷新时间（整个 refresh 批次的开始时间，所有账号共用）；失败时为 nil
    let refreshDate: Date?

    var id: String { "\(provider.rawValue):\(accountID)" }

    static func workBuddy(
        accountID: String,
        accountName: String,
        isCurrent: Bool,
        sourceUserID: String,
        refreshDate: Date? = nil
    ) -> AccountCreditStat {
        AccountCreditStat(
            provider: .workBuddy,
            accountID: accountID,
            accountName: accountName,
            isCurrent: isCurrent,
            unit: .credits,
            totalRemaining: nil,
            expiringSoonRemaining: 0,
            soonestExpireAt: nil,
            error: nil,
            sourceUserID: sourceUserID,
            refreshDate: refreshDate
        )
    }

    static func failure( // swiftlint:disable:this function_parameter_count
        provider: ManagedProvider,
        accountID: String,
        accountName: String,
        isCurrent: Bool,
        sourceUserID: String,
        error: String
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
            error: error,
            sourceUserID: sourceUserID,
            refreshDate: nil
        )
    }

    func resolving(
        totalRemaining: Double?,
        expiringSoonRemaining: Double,
        soonestExpireAt: Date?,
        unit: CreditUsageUnit,
        packages: [CreditPackage] = [],
        refreshDate: Date? = nil
    ) -> AccountCreditStat {
        AccountCreditStat(
            provider: provider,
            accountID: accountID,
            accountName: accountName,
            isCurrent: isCurrent,
            unit: unit,
            totalRemaining: totalRemaining,
            expiringSoonRemaining: expiringSoonRemaining,
            soonestExpireAt: soonestExpireAt,
            error: nil,
            sourceUserID: sourceUserID,
            packages: packages,
            refreshDate: refreshDate
        )
    }
}

// MARK: - 常量

enum CreditStatsRules {
    /// 近期到期阈值：剩余积分且在此天数内到期
    static let expiringSoonDays: TimeInterval = 7 * 24 * 3600
}

// MARK: - WorkBuddy billing 资源解析

enum WorkBuddyCreditParser {
    /// 从 billing 响应的多种嵌套路径提取账号数组。
    static func accounts(in response: [String: Any]) -> [[String: Any]] {
        let paths: [[String]] = [
            ["data", "Response", "Data", "Accounts"],
            ["data", "data", "Response", "Data", "Accounts"],
            ["data", "Accounts"],
            ["data", "data", "Accounts"],
            ["data", "accounts"],
            ["data", "data", "accounts"]
        ]
        for path in paths {
            if let array = valueAtPath(response, path) as? [[String: Any]] {
                return array
            }
            if let value = valueAtPath(response, path) as? [Any] {
                let accounts = value.compactMap { $0 as? [String: Any] }
                if !accounts.isEmpty {
                    return accounts
                }
            }
        }
        return []
    }

    static func hasAccounts(in response: [String: Any]) -> Bool {
        let paths: [[String]] = [
            ["data", "Response", "Data", "Accounts"],
            ["data", "data", "Response", "Data", "Accounts"],
            ["data", "Accounts"],
            ["data", "data", "Accounts"],
            ["data", "accounts"],
            ["data", "data", "accounts"]
        ]
        return paths.contains { path in
            valueAtPath(response, path) is [Any]
        }
    }

    /// 把账号记录解析为资源包（精度字段优先、回退其次）。
    static func resource(from account: [String: Any], now: Date = Date()) -> CreditResource {
        let total = Self.amount(
            in: account,
            preciseKeys: [
                "CycleCapacitySizePrecise",
                "CycleTotalCapacity",
                "CycleCapacitySize",
                "SlicePeriodCapacitySizePrecise",
                "SlicePeriodCapacitySize"
            ]
        )
        let remaining = Self.amount(
            in: account,
            preciseKeys: [
                "CycleCapacityRemainPrecise",
                "CycleRemainCapacity",
                "CycleCapacityRemain",
                "SlicePeriodCapacityRemainPrecise",
                "SlicePeriodCapacityRemain"
            ]
        )
        let used = Self.amount(
            in: account,
            preciseKeys: [
                "CycleCapacityUsedPrecise",
                "CycleUsedCapacity",
                "CycleCapacityUsed",
                "SlicePeriodCapacityUsedPrecise",
                "SlicePeriodCapacityUsed"
            ]
        )
        let resolvedTotal = total > 0 ? total : max(remaining + used, 0)
        let resolvedRemaining = total <= 0 && remaining <= 0
            ? max(resolvedTotal - used, 0)
            : remaining
        let resolvedUsed = used > 0 ? used : max(resolvedTotal - resolvedRemaining, 0)

        let expireAt = expiryDate(in: account)
        let expiringSoon = resolvedRemaining > 0 && (expireAt.map { now < $0 && $0 <= now.addingTimeInterval(CreditStatsRules.expiringSoonDays) } ?? false) // swiftlint:disable:this line_length
        let expired = resolvedRemaining > 0 && (expireAt.map { $0 <= now } ?? false)

        return CreditResource(
            packageCode: Self.string(account, keys: ["PackageCode", "packageCode"]),
            packageName: Self.string(account, keys: ["PackageName", "packageName"]),
            total: max(resolvedTotal, 0),
            remaining: max(resolvedRemaining, 0),
            used: max(resolvedUsed, 0),
            status: Self.integer(account, keys: ["Status", "status"]),
            expireAt: expireAt,
            expired: expired,
            expiringSoon: expiringSoon
        )
    }

    /// 汇总资源列表 → 卡片数值。
    static func summarize(
        _ resources: [CreditResource],
        now: Date = Date()
    ) -> WorkBuddyCreditSummary {
        let totalRemaining = resources.reduce(0) { $0 + $1.remaining }
        let expiringSoonRemaining = resources
            .filter { $0.expiringSoon }
            .reduce(0) { $0 + $1.remaining }
        let soonestExpireAt = resources
            .filter { $0.remaining > 0 }
            .compactMap(\.expireAt)
            .min()
        return WorkBuddyCreditSummary(
            totalRemaining: totalRemaining,
            expiringSoonRemaining: expiringSoonRemaining,
            soonestExpireAt: soonestExpireAt
        )
    }

    private static func expiryDate(in account: [String: Any]) -> Date? {
        let keys = ["DeductionEndTime", "ExpiredTime", "CycleEndTime"]
        return timestamp(string(account, keys: keys))
            ?? timestamp(numeric(account, keys: keys))
    }

    /// 资源包 → 展示明细（全部积分包列表）。
    static func packages(from resources: [CreditResource]) -> [CreditPackage] {
        resources.map { resource in
            CreditPackage(
                name: resource.packageName
                    ?? resource.packageCode
                    ?? "未命名资源包",
                total: resource.total,
                remaining: resource.remaining,
                used: resource.used,
                expireAt: resource.expireAt,
                expired: resource.expired,
                expiringSoon: resource.expiringSoon
            )
        }
    }

    // MARK: - 字段提取

    static func timestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let options = ISO8601DateFormatter().date(from: value) {
            return options
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let parsed = formatter.date(from: value) {
            return parsed
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        if let parsed = formatter.date(from: value) {
            return parsed
        }
        formatter.dateFormat = "yyyy-MM-dd"
        if let parsed = formatter.date(from: value),
           let endOfDay = Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 59,
            of: parsed
           ) {
            return endOfDay
        }
        return nil
    }

    static func timestamp(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        let seconds = abs(value) < 10_000_000_000 ? value : value / 1_000
        return Date(timeIntervalSince1970: seconds)
    }

    static func timestamp(_ value: Any?) -> Date? {
        if let numeric = value as? NSNumber {
            return timestamp(numeric.doubleValue)
        }
        if let text = value as? String {
            if let numeric = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return timestamp(numeric)
            }
            return timestamp(text)
        }
        return nil
    }

    static func amount(in dict: [String: Any], preciseKeys: [String]) -> Double {
        for key in preciseKeys {
            // 存在且可解析即采用（含合法的 0），不因值为 0 回退到旧字段
            if let number = numeric(dict, keys: [key]) {
                return number
            }
        }
        return 0
    }

    /// 记录中是否含任何可识别为有限数值的容量字段（区分「合法 0」与「格式无法识别」）。
    static func hasParsableCapacityFields(_ account: [String: Any]) -> Bool {
        let sizeKeys = [
            "CycleCapacitySizePrecise", "CycleTotalCapacity", "CycleCapacitySize",
            "SlicePeriodCapacitySizePrecise", "SlicePeriodCapacitySize"
        ]
        let remainKeys = [
            "CycleCapacityRemainPrecise", "CycleRemainCapacity", "CycleCapacityRemain",
            "SlicePeriodCapacityRemainPrecise", "SlicePeriodCapacityRemain"
        ]
        let usedKeys = [
            "CycleCapacityUsedPrecise", "CycleUsedCapacity", "CycleCapacityUsed",
            "SlicePeriodCapacityUsedPrecise", "SlicePeriodCapacityUsed"
        ]
        return (sizeKeys + remainKeys + usedKeys).contains { key in
            numeric(account, keys: [key]) != nil
        }
    }

    static func numeric(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let number = value as? NSNumber {
                let result = number.doubleValue
                if result.isFinite { return result }
            }
            if let text = value as? String,
               let result = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               result.isFinite {
                return result
            }
        }
        return nil
    }

    static func integer(_ dict: [String: Any], keys: [String]) -> Int? {
        guard
            let value = numeric(dict, keys: keys),
            value >= Double(Int.min),
            value <= Double(Int.max)
        else {
            return nil
        }
        return Int(value)
    }

    static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    static func valueAtPath(_ dict: [String: Any], _ path: [String]) -> Any? {
        var current: Any = dict
        for key in path {
            guard let object = current as? [String: Any] else { return nil }
            current = object[key] as Any
        }
        return current
    }
}
