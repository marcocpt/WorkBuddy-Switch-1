# 设计规格：概览页积分统计卡片

- 版本：v1（未批准草图，等待自检后定版）
- 上游：requirements.md v1（本目录同版本族）
- 范围引用：FR-1 ~ FR-11，NFR-1 ~ NFR-6

---

## 1. 分工（WHO）

### 1.1 解析层（纯数据，无 IO、无 UI）

- 职责：定义积分统计的领域模型；WorkBuddy billing 响应的资源包解析；Trae 额度模型 → 卡片视图模型的映射；账号卡片的聚合与排序。
- 不负责：网络、认证、钥匙串、UI、Store 状态。
- 模型（Codable/Hashable/Sendable）：
  - `CreditResource`：packageCode、packageName、total、remaining、used、status、expireAt(Date?)、expired、expiringSoon。
  - `AccountCreditStat`（视图模型）：provider（ManagedProvider）、accountID、accountName、isCurrent、unit（credits/requests/unlimited）、totalRemaining(Double?)、expiringSoonRemaining(Double)、soonestExpireAt(Date?)、error(String?)、isLoading(由界面层持有)。
- WorkBuddy 资源解析（纯函数）：入参为 billing 接口 JSON（`data.Response.Data.Accounts[]` 或等效路径），输出 `[CreditResource]`。字段取 precision 优先、fallback 次之；到期时间支持 毫秒/秒/ISO8601/`yyyy-MM-dd HH:mm:ss`/`yyyy-MM-dd`；`expiringSoon` = 剩余>0 且 now < expireAt ≤ now+7d；`expired` = expireAt ≤ now 且剩余>0。
- Trae 映射（纯函数）：入参 `TraeQuotaSummary`，输出 `AccountCreditStat`。Credits 单位 → unit=credits、totalRemaining=remaining；请求单位 → unit=requests、totalRemaining=remaining；total=nil → unit=unlimited、totalRemaining=nil；soonestExpireAt=resetsAt；expiringSoon= resetsAt ≤ now+7d（仅 remaining>0 或 unlimited 时计）。
- 排序（纯函数）：WorkBuddy 账号（按 lastUsedAt 倒序）→ Trae CN 账号 → TRAE Work 账号；组内保持传入顺序。

### 1.2 服务层（网络编排，与 Store 解耦）

- 职责：逐账号并行拉取积分数据；故障隔离；HTTP 安全策略；超时与并发上限。
- 不负责：UI、持久化、钥匙串写入。
- `CreditStatsService`（actor）：
  - `refresh(workBuddyAccounts:[(profile, authData)], traeAccounts: …, activeWorkBuddyUserID, activeTraeUserIDs) async -> [AccountCreditStat]`
  - WorkBuddy 单账号查询：注入 `URLSession`、官方 hosts 白名单/校验、Authorization Bearer、12s 超时；401/403 → 该账号 error="登录已过期"。
  - Trae 单账号查询：调用既有 `TraeUsageService.fetchQuota(snapshot:)`（新增公共方法，复用 `withAuthRetry`）；401 → error="登录已过期"。
  - 并行执行，整体并发上限（信号量/结构化并发 ≤ 4）；单账号内部对象化失败不中断整体。
- 网络层复用 `URLSessionTraeHTTPClient`/`TraeOfficialHostPolicy` 的白名单与重定向策略；WorkBuddy 请求沿用 `https://www.codebuddy.cn` 官方主机的 Bearer 调用（与 `UsageService.fetchQuota` 同一主机，不做域名拼接）。

### 1.3 编排层（MainActor，AppState）

- 职责：持有积分统计状态；在概览刷新链路上触发积分刷新并按代际合并；暴露给界面层。
- 状态：持有「积分统计数组 / 积分刷新中布尔 / 整体提示」三类可发布状态。
- 触发点：在概览主刷新流程内，与用量/额度刷新并行发起积分刷新；用刷新代际校验丢弃过期结果。
- 数据装配：从 WorkBuddy 账号仓库（含凭据字节读取）与 Trae 账号仓库（含快照读取）构造入参；激活账号标记由两个仓库的「当前账号」状态提供。
- 不负责：任何解析与真实网络细节（委托 1.2）。

### 1.4 仓库补充（最小侵入）

- WorkBuddy 账号仓库：新增只读方法族「按账号 ID 读取钥匙串中该账号的凭据原始字节」，供 billing 查询使用（相当于复用既有钥匙串读能力的薄封装）。不得新增任何写路径。
- Trae 用量服务：把既有「以指定账号快照发起额度和用量请求」的私有能力提升为一个公共入口（与现有「按当前账号发起请求」的公共入口并列，认证重试语义不变）。

### 1.5 界面层（SwiftUI，OverviewView）

- 职责：积分统计区的渲染、加载态、错误态。
- 不负责：任何业务计算。
- 位置：`OverviewView.body` 的 ScrollView VStack 最上方，先于 `hero`。
- 形态：区块标题「积分统计」+ 响应式卡片网格（LazyVGrid，与现有 MetricTile 网格口径一致）；每卡片含：provider 图标+账号名+「当前」徽标、主数值（总积分/不限量/请求）、近期到期行（数值 + 日期，无近期到期时显示最近到期或「—」）、错误行（内联红字）。

## 2. 数据流

### 2.1 概览刷新 → 积分更新

```text
用户点刷新 / 切账号 / 切 provider / 自动周期
  → 概览主刷新流程 →（并行）用量/额度刷新 + 积分刷新
  → 积分刷新：
      装配账号集（WorkBuddy: 账号+凭据字节；Trae: 账号+快照）
      → 积分统计服务（≤4 并发逐账号拉取）
       ├─ WorkBuddy：billing 资源接口（Bearer）→ 资源解析 → 汇总
       ├─ Trae：按快照拉取额度 → 映射
       └─ 单账号失败 → error 落卡片
  → 结果按排序规则成数组
  → 刷新代际校验通过则发布新状态
```

### 2.2 故障隔离

```text
账号A 401 / 超时 / 格式错 → A 卡片 error；其余 B、C… 卡片正常展示
无已保存账号 → 积分区不渲染
```

## 3. 状态

- 新增 `creditStats`（离线不可用，仅随刷新更新）与 `creditStatsLoading`（布尔）。
- 加载态语义：任一刷新在进行时置真；代际过期即丢弃结果。
- 不引入持久化/缓存文件；无跨会话状态。

## 4. 账号身份与排序

- 身份：WorkBuddy 用 `profile.id`；Trae 用 `profile.variant + userID`（即 `profile.id`）。
- 排序（默认，见 requirements §11）：WorkBuddy（lastUsedAt 倒序）→ Trae CN → TRAE Work；后续可改 by 排序函数集中化。
- 命名：索引昵称优先，缺失用 `shortID`。

## 5. 安全边界

- HTTP 仅发往：WorkBuddy `https://www.codebuddy.cn`（billing 接口，沿用现有 fetchQuota 主机与 Bearer 头）；Trae 复用 `TraeOfficialHostPolicy` 白名单 + redirect 校验。
- 卡片/日志/索引均不含 token；`AccountCreditStat` 不含凭据字段。
- Trae 非激活账号查询使用快照凭据；`withAuthRetry` 仅在 storage.json 当前身份与目标一致时才回退使用（既有语义），不会改写 storage.json。

## 6. FR 映射

| FR | 落实 |
|---|---|
| FR-1/FR-2 | OverviewView 顶部新增积分统计区，逐账号卡片（1.5） |
| FR-3 | AccountCreditStat.totalRemaining 渲染；nil → 「—」/「不限量」（1.1） |
| FR-4 | expiringSoonRemaining + soonestExpireAt 渲染（1.1/1.5） |
| FR-5 | CreditStatsService 分 WorkBuddy/Trae 两路查询（1.2） |
| FR-6 | 账号命名 + 当前徽标（1.1/1.5） |
| FR-7 | AppState.refreshAll 联动 + creditStatsLoading（1.3） |
| FR-8 | 逐账号 do/catch → error 落卡片（1.2） |
| FR-9 | 401/403 → 内联 error（1.2/1.5） |
| FR-10 | refreshGeneration 校验（1.3） |
| FR-11 | 安全边界（§5） |

## 7. NFR 落实

- NFR-1：并发上限 ≤4（结构化并发/信号量）。
- NFR-2：WorkBuddy 单请求超时 12s；Trae 复用既有额度服务超时与认证重试语义（20s 单请求 + 重试预算），不做额外收紧。
- NFR-3：macOS 13+、Swift 5.7、无新依赖（复用 URLSession）。
- NFR-4：中文文案、命中目标 ≥15px、加载/错误可见。
- NFR-5：逐账号并行 + 超时兜底；数十账号量级无卡顿。
- NFR-6：只读网络与本机读取，无任何写路径。

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| 保存的 Trae 快照 token 过期 → 卡片误判数据 | fetchQuota(snapshot:) 复用既有 withAuthRetry：仅在目标身份= storage.json 当前身份时才用新凭据，否则按过期处理 |
| WorkBuddy 保存账号 token 过期（无刷新链路） | 卡片显示「登录已过期」内联；不阻塞 |
| 大量账号同时刷新 → 请求风暴 | ≤4 并发 + 12s 超时 |
| 卡片数据与「当前账号额度面板」口径差异（聚合 vs 资源级） | 明确：积分卡为资源级汇总，额度面板为周期额度，两者并存不互替 |
| UI 无本地 XCUITest | 界面层保持薄渲染；解析/排序/映射全部下沉纯函数并单测；UI 以手动截图取证 |

## 9. 交付物清单

- Sources：`CreditStatsModels.swift`（模型+解析+映射+排序）、`CreditStatsService.swift`、`AccountStore.authData(for:)`、`TraeUsageService.fetchQuota(snapshot:)`、`AppState` 状态与刷新联动、`OverviewView` 积分统计区。
- Tests：`SelfTest.swift` 增加解析/映射/排序/隔离用例。
- Docs：本目录规格套件。

## 10. 修订记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1 | 2026-09-14 | 初稿；NFR-2 随 requirements v1 修订（Trae 超时沿用既有服务） |