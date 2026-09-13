# 导入 / 导出所有已保存账号 · Phase 2：加密文件编解码

> **面向 AI 代理的工作者：** 由 `dd-feature-development-workflow` 的 Implementation Stage 逐 Phase 执行本计划；步骤使用复选框（`- [ ]`）跟踪进度。

**目标：** 实现备份文件字节布局（头部 + AES-256-GCM 认证密文）与 PBKDF2 密码派生，覆盖 T-CR-01..04。

**架构：** 新增纯函数式文件编解码器：Data 进、Data 出；无状态、无 IO；密钥派生用 CommonCrypto（CCKeyDerivationPBKDF），认证加密用 CryptoKit（AES.GCM）。

**技术栈：** Swift 5.7 / macOS 13 / CommonCrypto + CryptoKit。

---

## source_manifest

```yaml
source_manifest:
  REQ:
    stable_id: REQ
    path: docs/specs/import-export-accounts/requirements.md
    digest: sha256:ee63a8b9d6a52df3622e456b4a1199e5a38a63ecb6a5c25b765cbab0b2795c4d
    approval: {status: approved, authority: auto-approved (user auto-execution preference 2026-09-08), decided_at: 2026-09-13, evidence_ref: docs/specs/import-export-accounts/requirements.md#L117}
    version_label: v1
  DSG:
    stable_id: DSG
    path: docs/specs/import-export-accounts/design.md
    digest: sha256:53e21fcb288e77f16469230d1e05665879de1304f730c124b2abcab89e1b912f
    approval: {status: approved, authority: auto-approved (user auto-execution preference 2026-09-08), decided_at: 2026-09-13, evidence_ref: docs/specs/import-export-accounts/design.md#L143}
    version_label: v1
  TST:
    stable_id: TST
    path: docs/specs/import-export-accounts/test-matrix.md
    digest: sha256:d561f4942946cfc1d5cf92499e6e360bb4381fe32b77137e681dcf832d8d0b1e
    approval: {status: approved, authority: auto-approved (user auto-execution preference 2026-09-08), decided_at: 2026-09-13, evidence_ref: docs/specs/import-export-accounts/test-matrix.md#L67}
    version_label: v1
```

### 任务 2-1：文件头 + 密钥派生 + 认证加密 / 解密

**Sources：** `sources: [{ref: REQ, anchors: [FR-2, FR-7, FR-12, AC-2, AC-4, NFR-1, NFR-6]}, {ref: DSG, anchors: ["§1.2 加密编码层", "§2.1 导出", "§2.2 导入", "§5 兼容性与版本策略", "§7 NFR 落实"]}]`

**Consumes：** 字节布局规格（design §1.2），密码语义（空密码禁止）。

**Produces：**
- `enum AccountBackupFile: Sendable`：
  - `static let magic: Data` —— 8 字节固定序列 `0x57 0x42 0x53 0x41 0x43 0x43 0x54 0x31`（"WBSACCT1"），用于快速识别；
  - `static let currentFormatVersion: UInt8 = 1`；
  - `static let kdfAlgorithm: UInt8 = 1`（PBKDF2-HMAC-SHA256）；
  - `static let pbkdf2Iterations: UInt32 = 210_000`；
  - `static func encryptedFile(payloadJSON: Data, password: String) throws -> Data`；
  - `static func decryptedPayload(fileData: Data, password: String) throws -> Data`（返回载荷 JSON 字节）。
- `enum AccountBackupFileError: LocalizedError, Equatable, Sendable { case emptyPassword, notABackupFile, unsupportedVersion, malformed, authenticationFailed }`，errorDescription 为中文可读文案。
- 布局（写）：`magic(8) + version(1) + kdf(1) + iterations(4,BE) + salt(16) + nonce(12) + ciphertext + tag(16)`；AAD = 上述 magic..nonce 的 42 字节前缀。
- 派生：`CCKeyDerivationPBKDF(kCCPBKDF2, password, salt, kCCPRFHmacAlgSHA256, iterations, 32 bytes)`；盐/随机数用 `SecRandomCopyBytes`。
- 解密校验顺序：长度下限 → magic → version（≠1 → unsupportedVersion）→ kdf 标识（≠1 → malformed）→ 派生 → `AES.GCM.open` 失败 → authenticationFailed（密码错误或篡改统一语义）。`SECURITY.md` 安全承诺不含密码明文归档。

**Write scope：**
- 创建：`Sources/OpenUsage/AccountBackupFile.swift`
- 修改：`scripts/test.sh`（在源文件列表追加 `"$repo_root/Sources/OpenUsage/AccountBackupFile.swift"` 与 `"$repo_root/Sources/OpenUsage/AccountBackup.swift"`，并追加 `-framework CryptoKit`）

- [ ] **步骤 1：编写失败的测试**
  在 `Tests/SelfTest.swift` 追加：T-CR-01（同密码 往返==原文；密文≠原文；同密码两份文件字节不同）、T-CR-02（错误密码 → authenticationFailed）、T-CR-03（翻转密文末字节 → authenticationFailed；篡改 version 字节为 2 → unsupportedVersion；破坏 magic → notABackupFile）、T-CR-04（截断/空输入 → malformed 或 notABackupFile 语义，不崩溃）。
  ⚠️ 步骤 1 之前先登记 test.sh 源文件清单（否则无法编译新文件），把登记动作放在编写测试之前完成，一并验证。

- [ ] **步骤 2：运行测试验证失败**
  运行：`./scripts/test.sh`
  预期：编译失败（`AccountBackupFile` 未定义）或测试断言失败。

- [ ] **步骤 3：编写最少实现代码**
  实现 `AccountBackupFile.swift` 全部 Produces。注意：
  - `import CryptoKit` / `import CommonCrypto` / `import Security`；
  - GCM 需使用显式 nonce（12 字节）以绑定布局；AAD 必须为「magic..nonce 前缀」的原文（解密时从文件头重建相同 AAD）；
  - 大端迭代次数编码用 `withUnsafeBytes` 固定 4 字节；
  - 全部内存操作，无文件 IO。

- [ ] **步骤 4：运行测试验证通过**
  运行：`./scripts/test.sh`
  预期：`PASS`（退出码 0）。

- [ ] **步骤 5：SwiftPM 构建验证**
  修改：`Package.swift` 的 OpenUsage target `linkerSettings` 追加 `.linkedFramework("CryptoKit")`（与现有 AppKit/Security 并列）。
  运行：`swift build`
  预期：构建成功。

---

**Stop conditions：** 来源指纹与 manifest 不符 → stale 复核；CryptoKit 在 macOS 13 不可用或 seal/open 行为异常 → BLOCKED 并记录；本 Phase 产物不触发行 git 提交。

**Delivery authorization：** `{status: pending, actions: [commit], authority: 需要 ChatGPT 复审通过（未获得），evidence_ref: 用户规则}`