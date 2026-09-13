# 测试用例表：导入 / 导出所有已保存账号

- 版本：v1
- 上游：requirements.md v1、design.md v1、visual.md v1
- 执行范围：离线自测（Scripts/test.sh 编译并运行 Tests/SelfTest.swift）+ 界面人工/CI 证据。本地不执行 XCUITest（遵循项目规则）。

## 0. 总体说明

- 人口与注册表（compact）：离线用例采用「夹具生成器」构造——Trae 侧复用既有 fixture（FixtureTraeVault、fixtureTraeAuth/fixtureTraeStorage、临时目录索引），WorkBuddy 侧备份核心以纯数据（资料 + 凭据字节）驱动，不触碰真实钥匙串。
- 判定依据（oracle）：备份载荷往返后字段逐项相等；认证加密 解密成功 / 篡改失败；冲突决策输出可穷举；导入计数 N/M/K 与构造数据一致。
- 证据格式：SelfTest 断言通过即 PASS（脚本退出 0）；UI 证据按 §4 人工核对项登记截图/手动路径。
- 版本依赖：本表绑定 requirements v1 / design v1 / visual v1。

## 1. 用例清单（离线，SelfTest）

| ID | 验证（引用 FR/AC） | 差异断言（不复写 AC） | 需要夹具 |
|---|---|---|---|
| T-CR-01 | FR-2/AC-2：加密文件 = 密码派生密钥 + GCM | 同密码往返解密 == 原文；密文 ≠ 原文；两次随机盐/IV 不同（同密码两份文件不同） | 纯数据 |
| T-CR-02 | FR-2/AC-2：错误密码解密失败 | 返回「密码错误/认证失败」语义，不抛崩溃 | 纯数据 |
| T-CR-03 | FR-7/FR-12/AC-4：篡改与降级防护 | 密文任一字节翻转 → 认证失败；头部版本字节改成 2 → 版本拒绝；魔数破坏 → 无法识别 | 纯数据 |
| T-CR-04 | FR-12：截断/非法输入 | 截断尾字节 / 空字节 → 整体解析失败语义 | 纯数据 |
| T-PL-01 | FR-1/AC-1：载荷往返 | 构造三端混合记录（WorkBuddy 凭据字节 + Trae CN 快照 + Trae Work 快照）→ 编码 → 解码 → 逐字段相等 | 纯数据 |
| T-PL-02 | FR-7：格式自描述 | 载荷含格式标识、版本=1、导出时间 | 纯数据 |
| T-VL-01 | FR-11/AC-4：WorkBuddy 身份不一致拒绝 | 凭据解出 ID ≠ 元数据 ID → 记录判「失败（身份不一致）」；不写入 | 纯数据 |
| T-VL-02 | FR-11/AC-4：Trae 变体/ID 不一致拒绝 | 快照变体 ≠ 元数据变体 或 快照 ID ≠ 元数据 ID → 失败 | 纯数据（FixtureTraeVault 协助构造快照） |
| T-VL-03 | FR-11/AC-4：Trae 凭据内嵌身份拒绝 | authBlob 真实 userID ≠ 快照 userID 或 ≠ 元数据 ID → identityMismatch | 真实 fixture authBlob |
| T-VL-04 | FR-11/AC-4：provider/credential 错配拒绝 | .traeCN+.workBuddy 凭据、.workBuddy+.trae 凭据均 → identityMismatch | 纯数据 |
| T-CF-01 | FR-9/AC-5：钥匙串已有 → 跳过 | vault 已存在 → 决策 skip；不触发任何写入 | 纯函数 |
| T-CF-02 | FR-10/AC-5：钥匙串无+索引有 → 写入并保留元数据 | 写钥匙串；索引条目保留本机昵称（导入回复制该条目则元数据不变） | 纯函数 |
| T-CF-03 | FR-10：钥匙串无+索引无 → 写入并追加 | 写钥匙串；索引追加，昵称取导入值 | 纯函数 |
| T-CF-04 | FR-9/AC-5：apply 阶段 duplicate 计数 | vaultStatus=false 且 apply 返回 alreadyExists → 计入 skipped 而非 imported | 纯核心 |
| T-GT-01 | FR-14：导入计数与分类 | 1 新建 + 1 已有 + 1 非法 → N=1, M=1, K=1 且原因分类正确 | 纯数据 |
| T-GT-02 | FR-6：空导出拦截（编排前置） | 三端皆空 → 导出前置校验返回「无账号」，不产出文件字节 | 编排层纯入口 |
| T-ST-01 | FR-1/FR-8（Trae 端到端） | FixtureTraeVault + 临时索引：capture 两端各 1 账号 → 导出记录 == 捕获集 → 清空 vault/索引 → 导入 → 恢复；再导同一文件 → M=全量 | 既有 fixture 复用 |
| T-ST-02 | FR-5（Trae 侧导出无副作用） | 导出前后 vault 内容与索引逐字节一致 | 既有 fixture 复用 |
| T-ST-03 | FR-13（Trae 部分失败） | 用故障 vault（对指定账号抛错）→ 该账号计入失败 K，其余成功 | 故障夹具 |
| T-PROBE-01 | F-01 加固：存在性探测抛错 | vaultStatus 抛错 → 计入 failed，applyRecord 不被调用 | 纯核心 |
| T-INPUT-01 | 输入规模上限 | byteCount/accountCount 超限 → fileTooLarge/tooManyAccounts | 纯函数 |
| T-ORPHAN-01 | F-04 加固：索引失败补偿 | 索引保存失败 → 本次新建钥匙串项被回滚，无幽灵项 | 阻断索引夹具 |
| T-KDF-01 | NFR-1/AC-2：迭代次数解析与边界 | 加密/解密两侧 209999、2000001 → malformed；2000000 篡改 → authenticationFailed；210k v1 文件可解密 | 纯数据 |

## 2. 覆盖率回溯（FR → 用例）

- FR-1: T-PL-01, T-ST-01；（导出入口已由 T-GT-02 覆盖）
- FR-2/3: T-CR-01, T-CR-02（长度与两次一致校验属 UI 交互，见 §4）
- FR-4: T-PL-01, T-ST-02
- FR-5: T-ST-02
- FR-6: T-GT-02
- FR-7: T-PL-02, T-CR-03
- FR-8: T-ST-01
- FR-9/10: T-CF-01..03
- FR-11: T-VL-01, T-VL-02
- FR-12: T-CR-03, T-CR-04
- FR-13: T-ST-03
- FR-14: T-GT-01
- FR-15/16/17, AC-7/8/9: §4 界面与安全人工核对项

## 3. 数量与性能备注

- 规模（NFR-3）：加解密为纯 CPU；数百记录在一个导出/导入过程中完成时长纳秒~毫秒级，人工验证同机完成即可，不单列压测用例。

## 4. 界面与安全人工核对项（真实可见证据；本地人工，不上 XCUITest）

| ID | 验证（FR/AC） | 人工步骤要点 | 证据 |
|---|---|---|---|
| UI-01 | FR-17/AC-9 | 设置页出现「账号数据」区，两按钮样式与既有设置区一致；导出/导入按钮在切换进行中禁用 | 截图 + 状态观察 |
| UI-02 | FR-3/AC-2 | 导出：两次密码不一致/过短时按钮禁用且有红色提示；一致后进入保存面板；默认文件名含日期 | 截图 |
| UI-03 | FR-14/AC-6 | 导出成功 alert 显示账号数；导入成功 alert 显示 N/M/K | 截图 |
| UI-04 | FR-12/AC-4 | 错误密码/损坏文件 → 整体失败 alert，文案可读 | 截图 |
| UI-05 | FR-16/AC-8 | 全程后检查账号索引与本机日志不含 token/密码明文 | 索引文件 grep + 系统日志抽查 |

## 5. 修订记录

| 版本 | 日期 | 变更 | 针对 |
|---|---|---|---|
| v1 | 2026-09-13 | 定稿（自检通过，auto-approved） | d561f4942946cfc1d5cf92499e6e360bb4381fe32b77137e681dcf832d8d0b1e |
| v2 | 2026-09-13 | 登记 T-VL-03/04、T-CF-04、T-PROBE-01、T-INPUT-01、T-ORPHAN-01、T-KDF-01（grilling 复审 L-02 收口） | cc6c1267707e47635c62b4fc9a55d448e01570517a463c1fe43cd5cb75c4c733 |