# 导入 / 导出所有已保存账号 · Phase 4：设置页 UI 与交互接线

> **面向 AI 代理的工作者：** 由 `dd-feature-development-workflow` 的 Implementation Stage 逐 Phase 执行本计划；步骤使用复选框（`- [ ]`）跟踪进度。

**目标：** 在设置页落地「账号数据」区（导出 / 导入两个按钮）、密码 sheet、文件面板、结果提示与互斥/进行中状态；构建通过。UI 交互证据按 test-matrix §4 人工核对（本地不跑 XCUITest）。

**架构：** AppState 作为 UI 编排入口（busy 状态 + 互斥 + 结果 alert），SettingsView 呈现；加解密与文件 IO 放入后台 Task；Password sheet 为临时界面状态。

**技术栈：** SwiftUI / macOS 13 / NSSavePanel + NSOpenPanel + UTType。

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
  VIS:
    stable_id: VIS
    path: docs/specs/import-export-accounts/visual.md
    digest: sha256:8e8bc65f0415a5a6029ef4696c450f0694d8e9ed33029d2c49eba14af59272c5
    approval: {status: approved, authority: auto-approved (user auto-execution preference 2026-09-08), decided_at: 2026-09-13, evidence_ref: docs/specs/import-export-accounts/visual.md#L93}
    version_label: v1
  TST:
    stable_id: TST
    path: docs/specs/import-export-accounts/test-matrix.md
    digest: sha256:d561f4942946cfc1d5cf92499e6e360bb4381fe32b77137e681dcf832d8d0b1e
    approval: {status: approved, authority: auto-approved (user auto-execution preference 2026-09-08), decided_at: 2026-09-13, evidence_ref: docs/specs/import-export-accounts/test-matrix.md#L67}
    version_label: v1
```

### 任务 4-1：AppState 编排入口

**Sources：** `sources: [{ref: REQ, anchors: [FR-14, FR-15, FR-16, AC-3, AC-7, AC-8, AC-9]}, {ref: DSG, anchors: ["§1.4 界面层", "§2.1 导出", "§2.2 导入", "§3 状态"]}]`

**Consumes：** `AccountBackupService`、`AccountBackupFile`、`AccountsView`/`TraeAccountsView` 的互斥标记。

**Produces：**
- `AppState` 追加：
  - `@Published private(set) var isAccountBackupBusy = false`
  - `var hasAnySavedAccount: Bool`（accounts.accounts 非空 或 trae 两端任一非空）
  - `var canStartAccountBackup: Bool`（!isAccountBackupBusy && !accounts.isSwitching && traeAccounts.switchingVariant == nil）
  - `func exportAllAccounts(to url: URL, password: String)`：
    1. busy 互斥检查（不满足 → present 提示）；
    2. `try accountsBackup.buildExportPayload(...)`（空账号 → present「无法导出」）；
    3. `AccountBackupFile.encryptedFile()`（后台 Task.detached）；文件写入 `Data.write(to: url, options: [.atomic])` + 0600 权限;
    4. alert：导出完成（N 个，含 skippedWithoutSnapshot 说明 / 失败原因）。
  - `func importAccounts(from url: URL, password: String)`：
    1. busy 互斥检查；
    2. 后台：读文件 → `AccountBackupFile.decryptedPayload` → 解析 `BackupEnvelope`（版本校验兜底） → `importFromEnvelope`；
    3. 整体失败 → present「导入失败」对应文案；成功 → alert：导入 N / 跳过 M / 失败 K + 逐条原因。
  - 后台任务内保持 service.isBusy 与 AppState.isAccountBackupBusy 同步为 true，结束复位。
- 密码与凭据只在局部变量中出现（FR-16）。

**Write scope：**
- 修改：`Sources/OpenUsage/AppState.swift`

- [ ] **步骤 1：编写最少实现代码**
  直接实现上述 Produces（本任务主要是编排胶水，验证以 Phase 4 任务 4-2/4-3 的编译与人工核对为主）。

- [ ] **步骤 2：编译验证**
  运行：`swift build`
  预期：构建成功。

### 任务 4-2：设置页「账号数据」区 + 密码 sheet + 文件面板

**Sources：** `sources: [{ref: VIS, anchors: ["§1 入口", "§2 导出密码", "§3 导入密码", "§4 结果提示", "§5 空态", "§6 可达性", "§7 视觉锚点"]}, {ref: REQ, anchors: [FR-2, FR-3, FR-6, FR-14, FR-15, FR-17, AC-2, AC-3, AC-7, AC-9]}]`

**Consumes：** Task 4-1 暴露的 AppState 方法；提交给 `SettingsView` 的交互契约。

**Produces：**
- `SettingsView` 追加：
  - `@State`：`backupSheet: BackupSheet?`（enum：exportPassword(两次)/importPassword）；`pendingExportURL`/`pendingImportURL: URL?`；`exportPassword/confirmExportPassword/importPassword: String`。
  - 「账号数据」区（visual.md §1 形态）：两行卡片按钮。
    - 导出：点击 → 无账号 → alert「无法导出」；否则弹出导出密码 sheet（visual.md §2；「继续导出」在 两次一致且 ≥8 位 前禁用，含红色提示）→ 保存面板（默认名 `WorkBuddy-Switch-账号备份-<yyyy-MM-dd>.wbsacct`，`UTType(filenameExtension: "wbsacct")`）→ `state.exportAllAccounts(to:password:)`。
    - 导入：点击 → 打开面板（可打开类型 .data + 自定义 wbsacct）→ 读字节 → 导入密码 sheet（visual.md §3）→ `state.importAccounts(from:password:)`。
  - 两个按钮 `.disabled(!state.canStartAccountBackup)`，busy 时行内 ProgressView；文案与间距与既有设置区一致（controlSize(.large)、命中目标 ≥15px）。
- 密码 sheet 与结果提示按 visual.md §2/3/4 呈现；所有文案 zh-Hans。

**Write scope：**
- 修改：`Sources/OpenUsage/SettingsView.swift`

- [ ] **步骤 1：编写最少实现代码**
  按 Produces 实现 UI。

- [ ] **步骤 2：编译验证**
  运行：`swift build`
  预期：构建成功。

### 任务 4-3：端到端构建 + 进程级冒烟

- [ ] **步骤 1：全量自测**
  运行：`./scripts/test.sh`
  预期：全部断言 PASS（含 Phase 1-3 新增），退出码 0。

- [ ] **步骤 2：SwiftPM 发布构建**
  运行：`swift build -c release`
  预期：构建成功。

- [ ] **步骤 3：人工核对（UI 证据，本地执行）**
  依 test-matrix §4 UI-01..05 核对（功能可用性 + 截图存档至 `docs/specs/import-export-accounts/evidence/`）。若无法在本地运行完整 UI，登记证据待 CI/手动补；不把「已实现」当作「已验证」。

---

**Stop conditions：** VIS/REQ 指纹不符 → stale 复核；文件面板/UTType 在沙箱或非沙箱下行为差异导致无法保存/打开 → 记录并走人工核对通道；互斥竞态（切换中触发备份）发现漏锁 → 回任务 4-1 修复后重跑。

**Delivery authorization：** `{status: pending, actions: [commit], authority: 需要 ChatGPT 复审通过（未获得），evidence_ref: 用户规则}`