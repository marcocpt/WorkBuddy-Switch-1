# 测试用例表：概览页积分统计卡片

- 版本：v1（未批准草图，等待自检后定版）
- 上游：requirements.md v1 + design.md v1（同版本族）
- 执行位置：`scripts/test.sh`（swiftc 自测二进制，本地仅单元；UI 无 XCUITest，见 UI 段）

---

## 1. Population 与 oracle

- 单元测试以 fixture JSON 为输入，解析/映射/排序纯函数输出对照预期值（确定性断言）。
- 集成（结算）以已存在三端各 1 账号的真实环境为对象；oracle = 官方接口返回值（WorkBuddy 资源接口 / Trae 额度接口）。
- 每用例断言计数并入 SelfTest 总 assertions。

## 2. 单元测试用例

| ID | FR/AC | 场景 | 差异化断言（关键） |
|---|---|---|---|
| T-PR-01 | FR-3 | WorkBuddy 资源解析：`CycleCapacityRemainPrecise` 优先、`CycleCapacityRemain` 回退 | 正确 total/remaining/used；precise 与 fallback 二选一 |
| T-PR-02 | FR-4 | 到期时间解析：毫秒/秒/ISO8601/`yyyy-MM-dd HH:mm:ss`/`yyyy-MM-dd` | 均转正确 Date；`yyyy-MM-dd` 视为当日 23:59:59 |
| T-PR-03 | FR-4 | expiringSoon 边界：剩余>0 且 now<expireAt≤now+7d 为 true；>7d 为 false；expired 为 false | 边界值（now+7d 整点）断言 |
| T-PR-04 | FR-4 | expired：expireAt≤now 且剩余>0 → expired=true | expired 标记与 expiringSoon=false |
| T-PR-05 | FR-3 | 汇总：多资源剩余求和为 totalRemaining；expiringSoonRemaining 只含近 7 天资源 | 求和与过滤断言 |
| T-PR-06 | FR-5 | 响应路径容错：`data.Response.Data.Accounts[]` 与 `data.Accounts[]` 两种形状均解析 | 两形状同输出 |
| T-PR-07 | FR-4/§9 | 空 Accounts 合法成功 → 空资源列表，非错误 | 不抛错、totalRemaining=0 |
| T-PR-08 | FR-8 | 非法/缺字段响应 → 解析失败 | 抛错或返回错误态（由服务层捕获） |
| T-TR-01 | FR-3 | Trae Credits 单位映射：remaining 有限 | unit=credits、totalRemaining=remaining、soonestExpireAt=resetsAt |
| T-TR-02 | FR-3 | Trae unlimited（total=nil） | unit=unlimited、totalRemaining=nil、显示「不限量」前置条件 |
| T-TR-03 | FR-3 | Trae requests 单位 | unit=requests、totalRemaining=请求剩余 |
| T-TR-04 | FR-4 | Trae resetsAt 在 7 天内 → expiringSoon=true | 边界断言 |
| T-SR-01 | FR-2/§11 | 排序：WorkBuddy（lastUsedAt 倒序）→ Trae CN → TRAE Work | 输出顺序断言 |
| T-ISO-01 | FR-8 | 混合结果：1 账号 error + 2 账号正常 | 仅该卡片 error，其余 totalRemaining 正常 |
| T-RACE-01 | FR-10 | 服务层返回后按代际丢弃 | 由 AppState 层测试/代码评审覆盖（UI 集成，见 §3） |
| T-PKG-01 | FR-13 | WorkBuddy 资源包 → 展示明细：名称回退、剩余/总量/已用、到期与 7 天/已到期状态 | 断言映射后的 CreditPackage 数值与标志 |
| T-PKG-02 | FR-13 | Trae 多权益包解析与映射：每包剩余 = limit-used，展示名、毫秒级到期 | parseQuota.packs + 卡片 packages 断言 |

## 3. 集成与 UI 证据

| ID | FR/AC | 场景 | 证据方式 |
|---|---|---|---|
| INT-01 | AC-2 | 三端各 1 账号已保存 → 概览积分区卡片数=账号总数，数值与官方一致 | 运行 .app 手动核对 + 截图 |
| INT-02 | AC-3 | 含 7 天内到期资源的账号 → 近期到期数值与日期正确 | 手动核对 + 截图 |
| UI-01 | AC-1 | 概览最顶部出现「积分统计」区；无账号时不渲染 | 截图（有账号 / 无账号两种） |
| UI-02 | AC-4 | 当前激活账号带「当前」徽标；无昵称显示 ID 缩写 | 截图 |
| UI-03 | AC-5 | 刷新按钮 → 加载态 → 更新 | 操作录像/截图 |
| UI-04 | AC-6 | 单账号过期/失败 → 该卡红字内联，其余正常 | 构造过期账号 + 截图 |
| UI-05 | AC-8 | 刷新后无 token 出现在日志/索引/设置 | 日志与文件抽查 |

说明：本地禁止 XCUITest（用户规则）；UI AC 以真实运行的 .app 手动验证 + 截图取证（沿用既有 evidence 目录约定）。UI 证据需真实界面，不接受 mock 层数断言替代。

## 4. 数值策略与精度

- 金额/积分比较采用 Double 近似断言（精度 1e-6），字符串展示断言在格式化层（DisplayFormat）测试。
- 分页/并发与超时属 NFR，由代码评审确认：并发上限 ≤4；WorkBuddy 单请求超时 12s；Trae 沿用额度服务既有 20s 单请求与认证重试语义（NFR-2 修订后口径）。

## 5. 修订记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1 | 2026-09-14 | 初稿；NFR-2 随 requirements v1 修订同步。T-PR-08 语义修订为「无法识别→失败」，补充 H-02/H-03/M-01 回归；增量：新增 T-PKG-01/02（全部积分包明细） |