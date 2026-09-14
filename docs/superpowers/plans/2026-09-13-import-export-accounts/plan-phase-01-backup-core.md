# 导入 / 导出所有已保存账号 · Phase 1：备份载荷核心（纯逻辑）

> **面向 AI 代理的工作者：** 由 `dd-feature-development-workflow` 的 Implementation Stage 逐 Phase 执行本计划；步骤使用复选框（`- [ ]`）跟踪进度。

**目标：** 建立备份载荷模型、记录校验、冲突决策与索引合并的纯逻辑层，并由离线自测覆盖（T-PL-01/02、T-VL-01/02、T-CF-01..03）。

**架构：** 新增纯数据/纯函数文件，只操作内存中的值对象，不触 IO、钥匙串、UI；SelfTest 直接以夹具构造记录断言。

**技术栈：** Swift 5.7 / macOS 13 / swiftc 自测脚本（Tests/SelfTest.swift）。

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

### 任务 1-1：载荷模型与校验（纯逻辑）

**Sources：** `sources: [{ref: REQ, anchors: [FR-1, FR-4, FR-7, FR-11]}, {ref: DSG, anchors: ["§1.1 备份载荷层", "§6 FR 映射"]}]`

**Consumes：** 既有类型 `AuthDocument`（已有 `init(data:) throws` 与 `userID`）、`TraeCredentialSnapshot`（Codable）、`TraeVariant`；业务含义见既有源文件。

**Produces：**
- 类型：`BackupProvider`、`BackupAccountMetadata`、`BackupCredential`（workBuddy(Data) / trae(TraeCredentialSnapshot)）、`BackupAccountRecord`、`BackupEnvelope`（format = "workbuddy-switch-accounts"，version = 1，exportedAt，accounts）。
- 纯函数：`validateBackupRecord(_:) -> BackupLoadError?`（nil=有效；workBuddy 用 `AuthDocument(data:).userID` 与 `metadata.accountID` 一致性核验；trae 用 `snapshot.variant` ↔ provider 映射 + `snapshot.userID` 一致性核验）；`traeVariant(for provider:) -> TraeVariant?`（traeCN→`.china`，traeWork→`.work`，workBuddy→nil）。
- 错误：`BackupLoadError.identityMismatch` / `.invalidCredential`。
- TraeCredentialSnapshot.trae 变体间传值：`BackupCredential.trae` 直接复用既有快照结构（不重定义凭据载体）。

**Write scope：**
- 创建：`Sources/OpenUsage/AccountBackup.swift`（仅本任务范围：模型 + 校验函数）

- [ ] **步骤 1：编写失败的测试**
  在 `Tests/SelfTest.swift` 追加一节（复用既有 fixture 语法与 expect 函数）：T-PL-01（三端混合记录 编码→解码→逐字段相等；TraeCredentialSnapshot 直接用字段构造）、T-PL-02（format/version/exportedAt 存在）、T-VL-01（workBuddy 凭据 userID ≠ 元数据 → identityMismatch；userID 匹配 → 校验通过）、T-VL-02（trae 变体不符 / userID 不符 → identityMismatch；traeWork→traeCN 映射错误 → 失败）。引用尚未存在的 `BackupEnvelope` 等符号，制造编译失败（RED）。

- [ ] **步骤 2：运行测试验证失败**
  运行：`./scripts/test.sh`
  预期：编译失败，原因：找不到 `BackupEnvelope` / `BackupAccountRecord` 等类型。

- [ ] **步骤 3：编写最少实现代码**
  在 `Sources/OpenUsage/AccountBackup.swift` 实现上述 Produces 全部类型与函数。注意：
  - Codable 需自定 `BackupCredential` 的 encode/decode（关联值枚举：case key "kind"，workBuddy=trait 字节用途 base64，trae=嵌套快照）。
  - 与 `AccountProfile` / `TraeAccountProfile` 的互转不在本任务（Phase 3 编排层负责），本模型采用独立 `BackupAccountMetadata` 字段。
  - 遵循项目风格：`Sendable`、`let` 优先；文件顶部 `import Foundation`。

- [ ] **步骤 4：运行测试验证通过**
  运行：`./scripts/test.sh`
  预期：`PASS`（断言计数增加，退出码 0）。

### 任务 1-2：冲突决策与索引合并（纯函数）

**Sources：** `sources: [{ref: REQ, anchors: [FR-9, FR-10, AC-5]}, {ref: DSG, anchors: ["§4 冲突与合并决策"]}]`

**Consumes：** Task 1-1 产出的 `BackupAccountMetadata`。

**Produces：**
- `enum BackupImportAction: Equatable, Sendable { case skip, apply }`
- `func backupImportAction(vaultHasRecord: Bool) -> BackupImportAction`（true→skip，false→apply）
- `func mergeIndexMetadata(existing: BackupAccountMetadata?, imported: BackupAccountMetadata) -> BackupAccountMetadata`（existing 非空→原样返回；为空→返回 imported）

**Write scope：**
- 修改：`Sources/OpenUsage/AccountBackup.swift`（追加）

- [ ] **步骤 1：编写失败的测试**
  追加：T-CF-01（vault 已有 → skip）、T-CF-02（vault 无 + 索引有：action=apply；merge 返回既有昵称、导入昵称被丢弃）、T-CF-03（vault 无 + 索引无：action=apply；merge 返回导入值）。

- [ ] **步骤 2：运行测试验证失败**
  运行：`./scripts/test.sh`
  预期：编译失败（`backupImportAction` / `mergeIndexMetadata` 未定义）。

- [ ] **步骤 3：编写最少实现代码**
  追加上述两个纯函数，策略严格按 §4 表格。

- [ ] **步骤 4：运行测试验证通过**
  运行：`./scripts/test.sh`
  预期：`PASS`。

---

**Stop conditions：** REQ/DSG/TST 任一指纹与 manifest 不符 → 标记 stale 并回规格复核，不继续；用例断言失败或类型契约不一致 → BLOCKED，先修复本 Phase 产物。

**Delivery authorization：** `{status: pending, actions: [commit], scope: 本 Phase 文件, authority: 用户规则要求 git 提交前 ChatGPT 复审通过（authority 未获得），evidence_ref: 用户画像规则 2026-09-09}` —— 本 Phase 不提交 git，仅本地 Green。