# 实施计划：概览页积分统计卡片

- 日期：2026-09-14
- 功能：overview-credit-stats
- 上游：docs/specs/overview-credit-stats（requirements/design/visual/test-matrix v1）
- source_manifest_digest：76f2bcae7686a2e17a1c9f40373ed407fc88a4cb6d2520eaa7a22efd7c6543e8
- 分支：feature/overview-credit-stats
- 测试入口：scripts/test.sh（swiftc 自测二进制）；构建：swift build；Lint：swiftlint；UI 本地无 XCUITest（手动截图取证）

---

## 阶段总览

| Phase | 主题 | 写入范围 | 验证 | AC |
|---|---|---|---|---|
| 1 | 解析层（模型/解析/映射/排序/汇总） | `CreditStatsModels.swift`、`Tests/SelfTest.swift`（新增用例） | scripts/test.sh 全绿 | AC-2/AC-3 数值正确性 |
| 2 | 服务层（网络编排/隔离/超时）+ 仓库补充 | `CreditStatsService.swift`、`AccountStore.swift`(+只读取凭据)、`TraeUsageService.swift`(+按快照拉额度公共入口) | swift build + 单元自测 | AC-6 隔离、FR-5 数据源 |
| 3 | 编排层（AppState 状态与联动/代际） | `AppState.swift` | swift build + 自测编译 | AC-5/AC-7 刷新联动与竞态 |
| 4 | 界面层（OverviewView 积分统计区） | `OverviewView.swift` | swift build；swiftlint | AC-1/AC-4 + UI 手动证据 |
| 5 | 文档与验证（changelog/证据/Local Gate 全跑） | `CHANGELOG.md`、evidence 截图 | build/selftest/swiftlint 全绿 | 全部 AC |

## 全局约束

- Out of Scope 见 requirements §5：不做历史/趋势/签到/自动切换/WorkBuddy token 刷新/持久化。
- 安全：token 不外露；WorkBuddy 仅发往 `https://www.codebuddy.cn`；Trae 复用官方主机白名单。
- HTTP 超时 12s；并发 ≤4。
- 新建文件：Sources/OpenUsage/CreditStatsModels.swift、Sources/OpenUsage/CreditStatsService.swift。

---

## Phase 1：解析层

- 交付：模型 + 纯函数解析/映射/排序/汇总；SelfTest 新用例。
- TDD：先行写纯函数测试（fixture JSON），再实现，再全绿。
- Test 锚点：T-PR-01~08、T-TR-01~04、T-SR-01、T-ISO-01（T-ISO-01 在服务层合并验证，这里先验证"错误态不污染正常项"的纯函数部分）。
- 实现锚点（requirements/design）：
  - `CreditResource` 字段与解析（design §1.1；字段命名对齐参考项目 CreditResource）。
  - WorkBuddy 资源 JSON → `[CreditResource]`：精度优先字段、到期时间多格式解析、expiringSoon(7d)/expired 判定、路径容错（data.Response.Data.Accounts / data.Accounts）。
  - `TraeQuotaSummary → AccountCreditStat` 映射：credits/requests/unlimited；soonestExpireAt=resetsAt；expiringSoon(7d)。
  - 排序/汇总纯函数。
- Local Gate：scripts/test.sh 全绿；swift build 通过。

## Phase 2：服务层 + 仓库补充

- 交付：CreditStatsService（逐账号并行拉取、故障隔离、超时、并发上限）；AccountStore 只读凭据字节；TraeUsageService 按快照拉额度公共入口。
- Test 锚点：T-ISO-01（1 账号 error + 其余正常，服务层集成式单测，用注入 client/mock）。
- 实现锚点：
  - CreditStatsService 使用注入的 URLSession / TraeUsageService；
  - WorkBuddy 分支：Bearer header + 官方主机 + 401/403→「登录已过期」；
  - Trae 分支：按快照拉额度（复用认证重试语义）；
  - 并行 ≤4（结构化并发 TaskGroup 改写），12s 超时。
- Local Gate：swift build；scripts/test.sh 全绿。

## Phase 3：编排层

- 交付：AppState 增加积分统计状态（数组/加载中），在概览主刷新流程内并行触发积分刷新，代际校验丢弃过期结果。
- Test 锚点：T-RACE-01（代际丢弃）——以代码评审 + 编译级验证为主（真实网络在 Local Gate 不可靠）。
- 实现锚点：design §1.3/§3；requirements FR-7/FR-10。
- Local Gate：swift build；scripts/test.sh 全绿。

## Phase 4：界面层

- 交付：OverviewView 顶部「积分统计」区（标题+卡片网格）；卡片含 名称/当前徽标/主数值/近期到期行/错误行/加载态；空账号不渲染。
- 实现锚点：design §1.5、visual.md §1~4。
- 验证：swift build；swiftlint；手动运行 .app 截图（有账号、无账号、错误态）→ evidence 目录。
- Local Gate：build + lint 通过；UI 证据路径建档（真实运行，不 mock）。

## Phase 5：文档与最终验证

- 交付：CHANGELOG 条目；证据汇总；全量 Local Gate（swift build / swift build -c release / scripts/test.sh / swiftlint 增量检查）。
- Gate：全部本地检查绿；UI 证据按 test-matrix §3 记录 manual 状态。

## 风险提示

- WorkBuddy 保存账号 token 可能过期（无刷新链路）→ 卡片错误态预期行为（FR-8/9）。
- Trae 非激活账号快照过期 → 复用认证重试语义得「登录已过期」错误态。
- 本地不做 XCUITest；UI 证据=真实运行截图（沿用既有 evidence 约定）。

## 修订记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1 | 2026-09-14 | 初稿 |