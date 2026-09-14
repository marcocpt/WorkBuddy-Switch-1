import Foundation
import Security

struct KeychainVault {
    private let service: String

    init(service: String = "com.koi128bit.openusage.workbuddy-account.v1") {
        self.service = service
    }

    func save(_ data: Data, account: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw OpenUsageError.keychain(message(for: updateStatus))
        }

        var insert = key
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenUsageError.keychain(message(for: addStatus))
        }
    }

    func load(account: String) throws -> Data {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw OpenUsageError.accountSnapshotMissing
            }
            throw OpenUsageError.keychain(message(for: status))
        }
        // 兼容迁移：把历史项的 accessibility 收敛到当前策略（仅切换路径使用）。
        let accessibilityStatus = SecItemUpdate(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary,
            [
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ] as CFDictionary
        )
        guard accessibilityStatus == errSecSuccess else {
            throw OpenUsageError.keychain(message(for: accessibilityStatus))
        }
        return data
    }

    /// 严格只读读取（不做 accessibility 迁移）。导出与存在性探测路径使用，保证「导出无副作用」。
    func loadData(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw OpenUsageError.accountSnapshotMissing
            }
            throw OpenUsageError.keychain(message(for: status))
        }
        return data
    }

    /// 无副作用存在性探测：存在=true，不存在=false，其他错误抛出（绝不当作「不存在」处理）。
    func probeExistence(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw OpenUsageError.keychain(message(for: status))
        }
    }

    /// 严格只读批量读取：单次 SecItemCopyMatching 取回 service 下全部凭据，按 account 映射。
    /// 避免按账号逐项发起 SecItemCopyMatching，从而减少 Keychain 锁定/未授权时的重复授权机会。
    /// 空字典表示 service 下无条目；Keychain 故障抛错，绝不当作空处理。
    func loadAllData() throws -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            // 用数字 limit：kSecMatchLimitAll 字符串与 kSecReturnData 组合在 macOS 13 返回 errSecParam(-50)。
            kSecMatchLimit as String: 10_000
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            var map: [String: Data] = [:]
            if let items = result as? [[String: Any]] {
                for item in items {
                    if let account = item[kSecAttrAccount as String] as? String,
                       let data = item[kSecValueData as String] as? Data {
                        map[account] = data
                    }
                }
            } else if let single = result as? [String: Any],
                      let account = single[kSecAttrAccount as String] as? String,
                      let data = single[kSecValueData as String] as? Data {
                map[account] = data
            }
            return map
        case errSecItemNotFound:
            return [:]
        default:
            throw OpenUsageError.keychain(message(for: status))
        }
    }

    /// 仅创建写入：已存在返回 false，绝不覆盖既有项；新插入返回 true。
    func insertIfAbsent(_ data: Data, account: String) throws -> Bool {
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(insert as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecDuplicateItem: return false
        default: throw OpenUsageError.keychain(message(for: status))
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenUsageError.keychain(message(for: status))
        }
    }

    private func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
