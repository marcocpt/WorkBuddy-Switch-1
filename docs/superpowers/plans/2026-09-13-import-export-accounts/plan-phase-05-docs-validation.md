# 导入 / 导出所有已保存账号 · Phase 5：文档同步与全量验证

> **面向 AI 代理的工作者：** 由 `dd-feature-development-workflow` 的 Implementation Stage 逐 Phase 执行本计划（最后一个本地 Gate）。

**目标：** 按最终行为同步 CHANGELOG 与 SECURITY；跑全量自测、发布构建与静态检查；产出 Phase 验证证据。

**架构：** 文档同步 + 验证聚合，不新增业务代码。

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
```

### 任务 5-1：CHANGELOG 与 SECURITY 同步

**Sources：** `sources: [{ref: REQ, anchors: [FR-2, FR-16, AC-8, NFR-1]}, {ref: DSG, anchors: ["§9 交付物清单"]]`

**Produces：**
- `CHANGELOG.md`「Unreleased」段追加条目（遵循既有中文条目风格）：
  - 新增设置页「账号数据」区：导出全部账号（WorkBuddy、Trae CN、TRAE Work 全部 Keychain 快照）为加密文件、可从文件导入恢复；已存在账号导入时自动跳过，不会被覆盖。
  - 导出文件使用用户密码加密（PBKDF2 + AES-256-GCM）；密码无法找回，备份文件丢失密码即不可读。
- `SECURITY.md`「Credential handling」或新增「Backup / restore」小节（README 安全节同步链接）：
  - 备份文件为加密容器（用户密码派生密钥，AES-256-GCM 认证加密），仅含钥匙串中既有凭据的镜像副本；
  - 密码不存储、不可找回（应用端无恢复通道）；导入恢复写回钥匙串后仍按既有存储策略；
  - 备份文件不写入日志/索引/常规设置；权限收敛（用户读写）。

**Write scope：**
- 修改：`CHANGELOG.md`、`SECURITY.md`

- [ ] **步骤 1：编写文档**
  依 Produces 落盘，中文，措辞与既有文档一致（不引入未实现能力描述）。

- [ ] **步骤 2：验证一致性**
  人工核对：文档描述与最终实现（Phase 1-4 产物）一致，无越界声明。

### 任务 5-2：全量 Gate

- [ ] **步骤 1：全量自测**
  运行：`./scripts/test.sh`
  预期：PASS。

- [ ] **步骤 2：发布构建 + 静态检查**
  运行：`swift build -c release`
  ，继而 `swiftlint`（默认规则，项目无自定义配置）
  预期：构建成功；swiftlint 无 error（warning 记录并说明，非阻塞）。

- [ ] **步骤 3：规格缺口复核**
  以 canonical-index.json 为基准，逐 FR/AC 复核：每个 FR 至少有一处实现落点与测试/证据引用；无越界需求实现。缺失 → 回对应 Phase 修正，不直接放行。

---

**Stop conditions：** 文档与实现不一致、lint error、测试失败 → 修复后重跑本 Phase，不得带病进入 Candidate。

**Delivery authorization：** `{status: pending, actions: [commit], authority: 需要 ChatGPT 复审通过（未获得），evidence_ref: 用户规则 —— 进入候选阶段后整体复审并提交}`