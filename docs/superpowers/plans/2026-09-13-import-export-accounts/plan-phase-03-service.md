# 导入 / 导出所有已保存账号 · Phase 3：编排层与仓库集成

> **面向 AI 代理的工作者：** 由 `dd-feature-development-workflow` 的 Implementation Stage 逐 Phase 执行本计划；步骤使用复选框（`- [ ]`）跟踪进度。

**目标：** 把载荷核心与文件编解码接成导出 / 导入两条流程，并为两个账号仓库补充只读枚举与快照写入薄封装；用 SelfTest 覆盖 T-GT-01/02 与 Trae 端到端 T-ST-01..03。

**架构：** `AccountBackupService`（MainActor，编排 + busy 状态）组合 WorkBuddy 仓库与 Trae 仓库的新增方法；Trae 侧可注入（既有 FixtureTraeVault + 临时索引）端到端自测；WorkBuddy 钥匙串为具体实现，其写入路径以薄封装存在，由编排层纯逻辑 + Trae 端到端双保险覆盖。

**技术栈：** Swift 5.7 / macOS 13 / SelfTest fixture 复用。

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

### 任务 3-1：仓库薄封装（枚举 + 快照写入）

**Sources：** `sources: [{ref: REQ, anchors: [FR-1, FR-4, FR-5, FR-8, FR-9, FR-10, AC-1]}, {ref: DSG, anchors: ["§1.3 编排层"]]`

**Consumes：** `AccountStore`、`TraeAccountStore` 既有公开/内部接口（vault 读写、索引保存、requireNoActiveSwitch 语义）。

**Produces：**
- `AccountStore` 追加：
  - `func backupExportItems() -> [(profile: AccountProfile, blob: Data?)]` —— 枚举索引账号，逐个读钥匙串，读不到则 blob=nil（不抛）；
  - `func importSnapshot(profile: AccountProfile, blob: Data) throws` —— 校验身份（`AuthDocument(data: blob).userID == profile.id`），写钥匙串，按 merge 语义合并索引（保留既有昵称），保存索引；失败不改变索引（先写钥匙串、加索引条目、再 saveIndex，顺序与既有 capture 一致）。
- `TraeAccountStore` 追加：
  - `func backupExportItems() -> [(profile: TraeAccountProfile, snapshot: TraeCredentialSnapshot?)]`
  - `func importSnapshot(profile: TraeAccountProfile, snapshot: TraeCredentialSnapshot) throws` —— 校验变体与 userID，写钥匙串，合并索引（保留既有昵称/email/头像），保存索引。

**Write scope：**
- 修改：`Sources/OpenUsage/AccountStore.swift`、`Sources/OpenUsage/TraeSupport.swift`

- [ ] **步骤 1：编写失败的测试**
  追加：T-ST-01（FixtureTraeVault + 临时索引：capture 两端各 1 → 导出记录集 == 捕获集 → 清空 vault/索引 → 导入 → 恢复 → 再导入同一包 → M=全量 且 N=0）、T-ST-02（导出前后 vault 内容与索引一致）、T-ST-03（构造对指定账号抛错的故障 vault：该账号计入失败 K，其余成功）。

- [ ] **步骤 2：运行测试验证失败**
  运行：`./scripts/test.sh`
  预期：编译失败（`backupExportItems` / `importSnapshot` 未定义）。

- [ ] **步骤 3：编写最少实现代码**
  按 Produces 实现。注意 WorkBuddy 侧 `importSnapshot` 的索引写入沿用 `saveIndex()` 私有方法；blob 校验失败抛 `BackupLoadError` 或既有错误语义，由调用方映射中文文案。

- [ ] **步骤 4：运行测试验证通过**
  运行：`./scripts/test.sh`
  预期：`PASS`。

### 任务 3-2：编排服务（导出 / 导入 / 计数 / 互斥）

**Sources：** `sources: [{ref: REQ, anchors: [FR-1, FR-4, FR-5, FR-6, FR-8, FR-9, FR-10, FR-11, FR-12, FR-13, FR-14, FR-15, AC-1, AC-4, AC-5, AC-6]}, {ref: DSG, anchors: ["§1.3 编排层", "§2.1 导出", "§2.2 导入", "§3 状态", "§8 风险与对策"]]`

**Consumes：** Task 1-1（校验）、1-2（冲突/合并）、2-1（文件编解码）、3-1（仓库封装）的全部 Produce。

**Produces：**
- `struct BackupExportSummary: Equatable, Sendable { var totalExported: Int; var skippedWithoutSnapshot: Int }`
- `struct BackupImportSummary: Equatable, Sendable { var imported: Int; var skipped: Int; var failed: Int; var failures: [String] }`
- `@MainActor final class AccountBackupService: ObservableObject`：
  - `@Published private(set) var isBusy = false`
  - `func buildExportPayload(workBuddy: AccountStore, traeAccounts: TraeAccountStore) throws -> (payload: BackupEnvelope, summary: BackupExportSummary)`
    - 空账号（三端皆无条目）→ 抛「没有可导出的账号」语义错误；
    - 每个条目：vault 无数据或校验失败 → `skippedWithoutSnapshot += 1` 并跳过该条目；否则构造 record；
    - 不触发任何写入。
  - `func importFromEnvelope(_ envelope: BackupEnvelope, workBuddy: AccountStore, traeAccounts: TraeAccountStore) -> BackupImportSummary`
    - 全量预校验：非法记录 → failed += 1（reason 中文）且不写；
    - 合法记录按 `backupImportAction(vaultHasRecord:)`：skip → skipped += 1；apply → 调仓库 `importSnapshot`，抛错 → failed += 1（reason），成功 → imported += 1；
    - 全程不写日志、不打印密码/token。

**Write scope：**
- 创建：`Sources/OpenUsage/AccountBackupService.swift`
- 修改：`scripts/test.sh`（追加新源文件登记）

- [ ] **步骤 1：编写失败的测试**
  追加：T-GT-01（1 新建 + 1 已有 + 1 非法 → N=1, M=1, K=1，failures 文案分类正确）、T-GT-02（三端全空 → buildExportPayload 抛「无可导出」且不产出 payload）。

- [ ] **步骤 2：运行测试验证失败**
  运行：`./scripts/test.sh`
  预期：编译失败（服务未定义）。

- [ ] **步骤 3：编写最少实现代码**
  按 Produces 实现 `AccountBackupService.swift`。

- [ ] **步骤 4：运行测试验证通过**
  运行：`./scripts/test.sh`
  预期：`PASS`。

---

**Stop conditions：** 指纹不符 → stale 复核；开关设计（互斥/忙状态）与 AppState 接缝按 DSG §3 实现，若发现需要 AppState 参与则在 Phase 4 接线时一并落地，此处不提前侵入。

**Delivery authorization：** `{status: pending, actions: [commit], authority: 需要 ChatGPT 复审通过（未获得），evidence_ref: 用户规则}`