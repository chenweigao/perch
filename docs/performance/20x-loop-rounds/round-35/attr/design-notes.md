# Round-35 设计笔记：分页全局索引 prepend 感知增量化（工作文档）

基线：529d41e（round-34 合并）。归因依据：round-34 报告（prepend 相 17,861 样本：
string-hash 17.54% + dict-find 9.22% + string-compare 9.35% ≈ 36% 字典机械；
inclusive 消费者 projectTurns 18.24% / History.init 15.74% / joined 13.43%；
timeline-make 仅 4.16% = turn 投影复用已生效）。

## 1. O(窗口) 热点清单（源码定位）

| # | 位置 | 每次 prepend 的成本 | 消费方 |
|---|---|---|---|
| H1 | ToolVisibilityProjection.projectTurns `owner.updateValue(index, forKey: id)` 全 turn identities 循环（:214-217） | ~16k 字符串哈希插入 + 重复检测 | anchored 冲突检查（:222-225 owner[id]≠index）、observedByTurn（:227-231）、prefixIdentities 键集 |
| H2 | `prefixIdentities = Set(owner.keys).union(observed…)`（:232） | O(窗口) Set 构建（再哈希） | separates() 检查、Prefix.identities、active 交集 |
| H3 | History.init `entryTurns[row.entry.id] = index` 全 rows（ConversationPresentation.swift:118-126） | ~9k 字符串哈希插入 | contains(entry:)（存在性）、presented(activity:) 的 byTurn 分组（:140） |
| H4 | projectTurns bounds 扫描 `for index in 1..<split where isUserPrompt`（:195-198） | O(窗口) 轻扫描 | bounds（turn 边界） |
| H5 | History rows/navigation 拼接 + joined 容器装配 | O(output) ARC 拷贝 | **本轮不动**（单一假设纪律；round-36 候选） |
| H6 | input sameWindow 验证 | O(窗口) 值比较 | 变更检测语义本体，不动 |

## 2. 方案：offset 相对序号 + COW 增量（H1-H4）

**核心不变量**：prepend 语义下既有 turn 的内容与相对顺序不变，仅绝对序号平移
delta。字典值改存 `rel = absolute - turnBase`：
- prepend：`turnBase' = turnBase - delta` ⇒ 旧条目 rel 不变而 absolute 自动 +delta；
- 新页条目 `rel = i - turnBase'`（i 为页内绝对序）；
- 字典本体 COW：`var dict = cached`（O(1) retain）→ 首次 mutation 一次性
  O(capacity) memcpy（无重新哈希，桶结构随拷贝保留）→ 插入 O(页 identity)。

**ToolVisibilityProjection 侧（H1+H2+H4）**：
- 新状态：`turnIDs: [String]`（每 turn 首消息 id，按序）、`ownerRel: [String: Int]`、
  `turnBase: Int`、`identitiesCache: Set<String>`（含 observed 修正项的键集）、
  `boundsCache: [Range<Int>]`（或可由 turnIDs+扫描重建）。
- prepend 检测：new turnIDs 必须以旧 turnIDs 为后缀（逐元素 ===/== 快路径，
  O(turns+delta)≈230 次指针比较）且旧 chunks 全部经 candidate 验证复用
  （`prior.chunk === chunk` 同一性）且 anchor/sessionID/online 不变。
- 满足 ⇒ ownerRel/identities/bounds 增量更新（COW+delta 插入+base 平移）；
  任一不满足 ⇒ 全量重建（=今日路径，语义回退安全）。
- **重复检测语义保持**：新页 identity 用 `updateValue(...) == nil` 守卫插入
  ownerRel——旧条目全在 COW 副本中，跨页重复 id 仍被拒绝（return nil ⇒
  整体投影回退 project() 路径）✓ 与今日全量构建的拒绝面一致。
- **中间 turn 重建的差分**：若某既有 turn 的 chunk 被重建（内容变更），其
  identities 可能变化——旧 identities 在 `Chunk.identities` 可得：从 ownerRel
  移除旧集（值==该 turn rel 的键）再插入新集。移除需按键遍历该 turn 旧
  identities（O(turn identities)，非 O(窗口)）✓。
- observed 修正项 `{ observed[k] where anchor ≠ current }`：anchor（最新
  user prompt id）在 prepend 下不变；observed 变化由 live 流驱动——
  identitiesCache 失效条件 = observed 版本变化（observed/order 变更时置 nil）。

**History 侧（H3）**：
- History 新状态：`entryTurnsRel: [String: Int]` + `turnBase: Int`（读取处
  `+turnBase` 还原绝对序号；contains 仅存在性不变）。
- 增量 init：`History(turns: built, prior: earlier)` ——当 built 的前 k 个
  turn 与 prior.turns **引用同一**（HistoryTurn 是 class，=== O(1)）且其余为
  新页 turn 时：entryTurnsRel = COW(prior.entryTurnsRel) + 仅新 turn 的 rows
  插入（rel 按新 base）；turnBase' = prior.turnBase - k… 注意 built 顺序 =
  [新页 turns…, 旧 turns…]（prepend），旧 turn 绝对序号 +k ⇒ base 平移同
  projectTurns。uniqueEntries = count 比较不变（rows.count 仍全量拼接后取）。
- rows/navigation 拼接**保持全量**（H5 本轮不动）——entryTurns 增量不改变
  rows 装配成本；预期收益 = H3 的 9k 哈希插入 + H1 16k + H2 Set 构建 + H4 扫描。

## 3. 等价论证要点（钉死面对应）

1. **输出等价**：所有增量路径与全量重建产生逐字节相同的
   Split/History/Presentation——差分测试：保留一份未修改投影实现
   （ReviewBaseline 模式，round-33 先例：改名副本同进程并跑），对
   {prepend 序列 × 编辑 × 重复 id × 跨页 turn × online 翻转 × anchor 变化 ×
   live tool 锚定} 矩阵逐字节比较。
2. **回退安全**：增量条件任一不满足 → 全量路径（今日代码）——增量只加
   快路径，不移除慢路径。
3. **重复检测**：跨页重复 id、页内重复 id、live 冲突（owner[id]≠index、
   turnAnchors 重复、anchored 归属）在增量下的拒绝行为与全量一致（差分
   矩阵覆盖）。
4. **失效面**：chunk 重建（内容变）、observed/order 变化、sessionID/online/
   anchor 变化、turnIDs 非纯 prepend 扩展 → 缓存丢弃全量重建。
5. **线程/生命周期**：ToolVisibilityProjection 与 History 均单线程使用
   （model 持有）；缓存为值类型字典 COW——无新增并发面。非缓存语义
   （不引入跨实例共享）⇒ **不触发"全局 memo"五点门控**（无新留存、无
   跨实例、无预算问题——缓存生命周期=宿主对象，成本=宿主已保留数据的
   索引副本；如实披露 ownerRel/identitiesCache 的额外内存 ≈ 既有字典量级）。

## 4. 预期与测量

- older_page_full_chain（Mac ~4.1ms）：字典机械 ~36% 中 H1-H4 可消除大部分
  （余 COW memcpy + 页内插入）⇒ 目标 -25~40%；配对指标承载，spread 分类器。
- streaming chain：update 路径本就走 canReuse 快路径（prefix 不变）——预期
  零变化（护栏验证）；首建/重建路径轻微受益。
- cold find_bar：无关（护栏）。
- 内存：ownerRel+identitiesCache+entryTurnsRel ≈ 与现有每调用临时字典同量级
  但**驻留**（跨调用持有至失效）——披露：单会话窗口 ~16k identity ×
  (24-32B/条) ≈ 0.5MB 量级 × 投影实例数。

## 5. 实施顺序

1. ToolVisibilityProjection 增量（H1/H2/H4）+ 差分矩阵钉死。
2. History.entryTurns 增量（H3）+ 钉死。
3. WorkbenchChecks 全绿 + 本地 bench sanity（older_page 应显著下降）。
4. 双平台六对 A/B（Mac 仲裁）+ 变异电池（增量条件旁路/差分遗漏/base 平移
   错误/失效缺失等形态）+ 评审 + 报告/INDEX。

风险登记：展示层正确性（折叠/可见性）为用户可见缺陷类——差分矩阵必须先于
性能测量；任何等价疑点 → 弃增量回全量（回退路径常存）。
