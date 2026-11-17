# Round-37 kickoff 笔记（round-36 合并后启动）

**基线**：round-36 merge sha（待合并后回填）。产品态：round-35 增量索引 +
round-36 joined foldParents 收养已落地；Mac older_page 两轮累计 -49.8%
（4.125→2.070ms）。

## 第一步：归因刷新（r37-attr.job，复用 r36 模板改 sha）

round-36 消灭了 joined 的字符串哈希/merge 主体（≈12.5% of prepend）。
剩余构成的待验证问题：
- Q1 rows 装配链现份额：History.init rows/navigation append（O(窗口)
  retain/装配）+ Snapshot.presented 行 341 `earlier.rows + rows` +
  Snapshot.rows computed `history.rows + tail`（每次访问重拼！）——ARC 族
  37.3% 中可归属到这三处的部分；
- Q2 sameWindow 验证族现份额（round-36 测 ~4%：KimiPart derived equals +
  canReuse + projectTurns closure）——正确性门槛，不可削弱，但**验证的
  调度**（每 prepend 全 chunk 重验 vs 增量信任边界）是否有设计空间需
  评审红线评估；
- Q3 update() 内联 ARC 9.2% + doDecrementSlow 9.0% 的构成细分（旧
  Snapshot/History/Presentation 死亡链——值语义固有还是可共享化）；
- Q4 narrative 5.2%/timeline-make 1.9% 异动检查（应不变）。

## 候选队列（round-36 后记确认序）

1. **键驻留**：同批 id 跨字典反复哈希（joined 收养后剩余哈希主体：
   projectTurns 0.48% + parents(of:into:) 0.44% + normalize 0.35% +
   collect 0.32% + entryTurns 插入 O(页)……）——单点份额可能已不足以
   立项，以 Q1-Q4 数据裁决；**红线：不得引入全局 memo**，有界缓存需
   五点论证。
2. **rows 装配/拼接链**（Q1 数据支撑则立项）：Snapshot.rows computed
   property 每访问重拼是显性浪费候选——但 API 形态（public [Row]）为
   红线，只能在实现内部缓存（memo rows 拼接结果，History 不可变 ⇒
   缓存安全）。
3. streaming input-compare（红线评估未做，暂不立项）。
4. displayMessages.getter 归因复核（需先解决符号化伪差疑问——探针或
   dwarf 走查；AgentWorkbench 调用侧=红线区，只能改 WorkbenchCore 侧
   实现）。
5. 若 Q1-Q4 无单点主导 ⇒ 评估轮收尾（round-34 先例）。

## 纪律备忘（沿 round-36）

- 收养/缓存类机制三件套钉死：harness memo 播种检查（reseed 教训）+
  反盲断言 + 插桩 trace 计数；顺序语义必须有使其可观测的 fixture 形态
  （wrong-order 教训）；oracle 探针（评审协作形态）优先于纯外部差分。
- A/B：v2 批 spread 异常紧可把家族性微小偏移推越带（round-35 紧 spread
  教训）——positives 越带先复测定性再下结论。
- 评审 delegate 发货时机：排在 Linux A/B 计时批**之后**（round-36 续审
  构建与 pair5-6 重叠一次，逐对核查无污染——不再重复）。

## 归因结果与立项裁决（r37-attr @b8e2d7a，15,644 prepend 样本）

round-36 达成确证：string-hash 9.83→4.17%、dict-find 4.60→1.74%、
history-join region 0.27%、joined residual 0.41%（收养 COW 成本实测
joinedIncremental ARC 1.21%，符合设计预估 2-3% 下沿）。

**剩余构成（prepend 相）**：
- ARC/bridge 42.9%：update() 内联 15.14%（主体=旧窗口 16k 元素释放链——
  previous=input 替换时旧 messages 缓冲析构，值语义固有；Input API=红线）
  + displayMessages.getter 3.37%（**归因未决——评审 F1 更正**：初稿
  「伪影收口」失实，harness 实际三处调用该 getter（r37-attr.job:122/148/153）
  且 in_flight_turn 非空 ⇒ 走 O(窗口) messages+[live] 拼接路径；prepend 相
  样本或含 warm 段相位边界污染（next-marker 规则，round-34 14.5% 先例）；
  无探针/DWARF 实验不得宣称伪影（round-33 F3 撤回先例）——未决推断、
  暂不选题；分页 20 页循环体内确无调用；产品侧流式形态每更新支付该
  拼接（AgentWorkbench 调用、getter 本体在 WorkbenchCore）⇒ 交 round-38
  流式复剖裁决）+ History
  deinit/init 3.9% + 字典析构 3.1% + harness 2.8%（调用方形态）+ 散点。
- string-compare 7.49%：KimiPart derived equals 2.78%（**cost-reuse 循环
  line 601 的整窗逐消息深比较**——retained-cost 复用门）+ sameWindow 族
  （canReuse 1.23 + projectTurns closure 0.90 + TV.update 0.54 + 叶 2.12）。
- input-compare region 2.88% = sameWindow/Input 帧（TV 验证主体，正确性门槛）。
- narrative 5.68%（round-20 否决在案）；teardown 8.83%（临时体析构，固有）；
  timeline-make 2.26%（O(页) 已增量）；model-update 4.23%（编排胶水）。

**双层验证发现（入队列；评审 interim 更正措辞）**：cost-reuse 循环
（line 601 深值 ==，~2.8%）与 TV chunk 复用验证（~5%）每次 prepend 各自
扫描同一后缀窗口；TV 侧为**位态结构层优先**（sameWindowBits 73B/消息，
round-33 实证）+深值回退（KimiProtocol.swift:314-321），与 cost 侧深值 ==
**深度与语义不同**——初稿「同一后缀字节各深走一遍」失准。去重可行性
取决于位态层能否覆盖 cost 准入等值需求（budget-0 钉死族），需红线评估+
精确语义分析：(a) cost == 是 retainedPayloadCost（缓存准入）语义门；
(b) sameWindow 是 chunk 复用正确性门；(c) 统一需 TV↔model 新 API
（架构耦合）。⇒ 非最小修改，本轮不立项。物理同一性快路径（buffer 地址比较+精确回退）估算收益
≈2.8-3.5%，低于分类器可信阈（spread 4-10%），单独立项预期不采纳。

**裁决：评估轮（round-34 先例）**——可攻单点均 ≤3.5%（低于噪声带可信
裁决阈值），其余为固有 churn/红线/否定清单。分页链已达当前架构的成本
地板：16k 窗口值语义下，每 prepend 不可约工作=调用方拼接 retain + 旧窗
释放 + 双重验证 + O(页) 投影 + O(output) 装配。

**队列重排（round-38+ 候选）**：
1. **流式链路复剖**（rounds 35/36 后 streaming 构成未刷新；chain_total
   ~1.3ms Linux——find 残项之外是否有新结构）；
2. 双重验证统一（需红线评估+五点论证级设计）；
3. narrative 新机制（round-20 否决仅约束旧机制）；
4. cold/find 红线封闭依旧（round-16/32 先例：一次性 vs 每次重开权衡）；
5. displayMessages 产品侧（调用方在 AgentWorkbench=红线区，仅可提案）。
