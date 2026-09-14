import CommonCrypto
import CryptoKit
import Foundation
import Security

/// 备份文件编解码错误（UI 直接映射为用户可读文案）。
enum AccountBackupFileError: LocalizedError, Equatable, Sendable {
    case emptyPassword
    case notABackupFile
    case unsupportedVersion
    case malformed
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "密码不能为空。"
        case .notABackupFile:
            return "所选文件不是 WorkBuddy Switch 备份文件。"
        case .unsupportedVersion:
            return "备份文件版本过高，请升级 WorkBuddy Switch 后再导入。"
        case .malformed:
            return "备份文件内容无法识别，可能已损坏。"
        case .authenticationFailed:
            return "密码错误，或备份文件已损坏。"
        }
    }
}

/// 备份文件加密容器：PBKDF2-HMAC-SHA256 派生密钥 + AES-256-GCM 认证加密。
///
/// 文件布局（设计 §1.2）：
/// ```text
/// magic(8) + version(1) + kdf(1) + iterations(4, big-endian)
/// + salt(16) + nonce(12) + ciphertext + tag(16)
/// ```
/// AAD = 头部前 42 字节（magic..nonce），防止头部任何字节被静默篡改。
enum AccountBackupFile: Sendable {
    /// "WBSACCT1"
    static let magic = Data([0x57, 0x42, 0x53, 0x41, 0x43, 0x43, 0x54, 0x31])
    static let currentFormatVersion: UInt8 = 1
    /// 1 = PBKDF2-HMAC-SHA256
    static let kdfAlgorithm: UInt8 = 1
    /// 默认派生迭代次数（OWASP 对 PBKDF2-HMAC-SHA256 的基准量级）。
    static let pbkdf2Iterations: UInt32 = 600_000
    /// 头部携带的参数仅接受该范围，防篡改/降级。下限对齐 canonical 设计「至少 21 万次」。
    static let minimumIterations: UInt32 = 210_000
    static let maximumIterations: UInt32 = 2_000_000

    static let saltLength = 16
    static let nonceLength = 12
    static let headerLength = magic.count + 1 + 1 + 4 + saltLength + nonceLength
    static let tagLength = 16

    static func encryptedFile(
        payloadJSON: Data,
        password: String,
        iterations: UInt32 = pbkdf2Iterations
    ) throws -> Data {
        guard !password.isEmpty else { throw AccountBackupFileError.emptyPassword }
        guard
            iterations >= minimumIterations,
            iterations <= maximumIterations
        else {
            throw AccountBackupFileError.malformed
        }

        var salt = Data(count: saltLength)
        var nonce = Data(count: nonceLength)
        let saltStatus = salt.withUnsafeMutableBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltLength, base)
        }
        let nonceStatus = nonce.withUnsafeMutableBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, nonceLength, base)
        }
        guard
            saltStatus == errSecSuccess,
            nonceStatus == errSecSuccess
        else {
            throw AccountBackupFileError.malformed
        }

        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        var header = Data()
        header.append(magic)
        header.append(currentFormatVersion)
        header.append(kdfAlgorithm)
        header.append(iterations.bigEndianBytes)
        header.append(salt)
        header.append(nonce)

        let sealed = try AES.GCM.seal(
            payloadJSON,
            using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: header
        )
        var file = header
        file.append(sealed.ciphertext)
        file.append(sealed.tag)
        return file
    }

    static func decryptedPayload(fileData: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw AccountBackupFileError.emptyPassword }
        guard fileData.count >= headerLength + tagLength else {
            throw AccountBackupFileError.malformed
        }
        guard Data(fileData.prefix(magic.count)) == magic else {
            throw AccountBackupFileError.notABackupFile
        }

        let version = fileData[fileData.startIndex + magic.count]
        guard version == currentFormatVersion else {
            throw AccountBackupFileError.unsupportedVersion
        }
        guard fileData[fileData.startIndex + magic.count + 1] == kdfAlgorithm else {
            throw AccountBackupFileError.malformed
        }

        let header = Data(fileData.prefix(headerLength))
        let iterationsStart = fileData.startIndex + magic.count + 1 + 1
        let iterations = Data(fileData[iterationsStart..<(iterationsStart + 4)])
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard
            iterations >= minimumIterations,
            iterations <= maximumIterations
        else {
            throw AccountBackupFileError.malformed
        }
        let saltStart = iterationsStart + 4
        let salt = Data(fileData[saltStart..<(saltStart + saltLength)])
        let nonceStart = saltStart + saltLength
        let nonce = Data(fileData[nonceStart..<(nonceStart + nonceLength)])

        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        let ciphertext = Data(fileData[(nonceStart + nonceLength)..<(fileData.endIndex - tagLength)])
        let tag = Data(fileData[(fileData.count - tagLength)...])
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        do {
            return try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: key),
                authenticating: header
            )
        } catch {
            throw AccountBackupFileError.authenticationFailed
        }
    }

    private static func derivedKey(
        password: String,
        salt: Data,
        iterations: UInt32
    ) throws -> Data {
        var derived = Data(count: 32)
        let derivedLength = derived.count
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withCString { passwordPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr,
                        password.utf8.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        derivedLength
                    )
                }
            }
        }
        guard status == 0 else { throw AccountBackupFileError.malformed }
        return derived
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: Data {
        withUnsafeBytes(of: bigEndian) { Data($0) }
    }
}
