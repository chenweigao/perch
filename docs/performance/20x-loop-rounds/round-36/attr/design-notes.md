# Round-36 设计笔记（kickoff，归因数据到达后修订）

**基线**：fd79884（round-35 合并：全局索引增量化，Mac older_page -35.39%，
Linux -42.75%）。**队列首位**（round-34 队列 + round-35 后记确认）：
容器装配（rows/navigation 拼接 + History.joined，round-34 测得 incl 13.43%）
与键驻留（同批 id 跨三字典反复哈希）。

## 第一步：现状归因刷新（进行中）

round-35 移除字典机械主体后，older_page 链路构成已变，**必须先重测份额再定
单一假设**（round-34 教训：归因表述错误 ⇒ 评审 F1 BLOCKING）。

- 作业：r36-attr.job（Mac Time Profiler，PAGING 形态 only，harness 血统
  round-34 benchR34PagingProfile，20 distinct-id 页/周期）。
- **本地保真干跑**（发货前，round-34 纪律）：harness triple 中位 6.056ms
  vs bench older_page_full_chain 6.49ms（比率 0.93，420 prepends/21 cycles
  @5s；round-34 同型比率 0.82）——harness 忠实，份额可外推。
- 分析器：analyze_r36.py（= analyze_r34.py 逐字节复用，regions/相位切分/
  consumer 归因逻辑不变；仅 docstring 更新）。

### 归因问题清单

- Q1 prepend 相构成：字典/字符串机械（arc-copy/string-hash/utf16-bridge/
  string-compare/dict-find）残余份额 vs 容器装配（history-join/alloc/
  teardown）vs 验证（cf-match/input-compare）？
- Q2 hash/dict 叶的 consumer 分布：projectTurns/History.init 是否如预期
  收缩？History.joined 是否升为首位 consumer？
- Q3 全窗验证（cf-match + input-compare + sameWindow 族）当前占比——
  round-35 后相对份额上升多少？
- Q4 narrative/timeline-make 有无异动（应不变——round-35 未触碰）。

### 候选决策树（以 Q1-Q3 数据裁决）

1. **joined/容器装配主导**（incl ≥10%）→ 假设=「History.joined 与 rows/
   navigation 拼接可按 turn 分段缓存，prepend 只付新页段的拼接」——设计
   问题：joined 的键与失效（turn 实例同一性沿 round-35 prior 通道？）、
   rows 消费方 API 形态（红线：不改变展示层输出；Array→分段结构的调用方
   适配面）、与 round-35 缓存态的失效联动（discardIndexes 同步）。
2. **键驻留主导**（同 id 多字典重复哈希可证）→ 单遍融合哈希/键 Interning
   ——注意否定清单：**不得引入全局 memo**；有界缓存需五点设计论证。
3. **验证主导** → prefix-verify 家族已 closed（round-33 否定清单：整窗
   前缀验证=设计内残项）——若数据指向此处，重排队列并如实记录不立项理由。
4. 其余（teardown/alloc ARC 散点）→ 无单点主导则评估轮收尾（round-34
   先例：归因+草图+不立项）。

## 红线备忘

- 不碰 Sources/AgentWorkbench；行为断言变化=回滚；否定清单有效
  （narrative round-20、prefix-verify round-33、collapsedWhitespace
  round-15、全局 memo 禁止）；门槛脚本不动；Linux 特有开销不算产品收益。
- A/B：同机交替六对、Mac 仲裁、等精度打印、positives 越带必须复测定性
  （round-35 紧 spread 批模式入册）。
- 停止规则计数 0/3；round-36 无采纳则 1/3。

## 归因结果（r36-attr @fd79884，Mac Time Profiler，1020 prepends，20,417 样本）

prepend 相 16,925 样本（82.9%）。round-35 目标达成确证：projectTurns
consumer 5.09%→**0.64%**，History.init 2.67%→跌出前八。

**新首位 consumer = History.joined（inclusive ≈12.5% of prepend）**：
- string-hash 叶深走查：joined 1129 样本 = 全部字符串哈希的 67.8% = 6.75%
- dict-find：joined 550 = 3.25%；string-compare：joined 385 = 2.27%；region 0.29%
- 机制：joined() 每次调用对**全窗口 folded ids 做 parents.merge**
  （逐 id 字符串哈希+探测+冲突比较）——History 实例每次 prepend 新建 ⇒
  实例级 memo 必失效 ⇒ merge 全量重做。

其余构成：ARC/bridge 族 37.3%（update() 内联 9.2% + doDecrementSlow 9.0% +
displayMessages.getter 2.7%【归因存疑：WorkbenchCore 内无调用方，疑 release
内联符号化伪差，round-33 F3 未决口径】+ 字典/数组临时体析构 ~9%——多为
值语义窗口切换的固有 churn，不可攻）；teardown 7.6%；narrative 5.2%
（round-20 否决）；sameWindow 验证族 ~4%（正确性门槛，不可削弱）；
input-compare（previous==input 整窗比较）= 设计内残项（否定清单 closed）。

## 立项：joined foldParents 沿 matched 对齐的 COW 收养（单一假设）

- History 保存 init 已算出的 matchedAlignment（consumed, leadingNew）。
- presented()：对齐存在 + prior 实例 memo 存在 + foldsProcess 相等 +
  **双方 activity 均为空**（v1 范围限定：overlay 场景走既有全量路径，
  产品主导形态=无 overlay；范围限定如实披露）⇒ joinedIncremental：
  parents = prior memo 的 foldParents COW 副本；先删消费 turn 的 fold ids
  （经 prior.turns[0].presented 的 turn 级 memo 命中取得），再覆盖插入
  leading turns 的 fold ids（earlier-turn-wins 语义与全量 merge 一致；
  **删除先于插入**——merge 情形下合并 turn 重携消费 turn 的 ids，顺序
  颠倒会丢失）；rows = leading presented rows ++ prior memo rows 的
  dropFirst(consumed 行数) 单次装配（平面数组装配本身 memcpy 最优，
  COW 收养无净益——rows 不收养，仅 parents 字典收养：哈希/探测 → 免）。
- 失效面：对齐失败/prior memo 缺失（prior 未曾 presented）/foldsProcess
  不等/activity 非空/leading turn presented 为 nil ⇒ 全量 joined（既有路径）。
- 等价论证：唯一 id 门（uniqueEntries）保证 fold ids 窗口内唯一；消费与
  leading 的 id 集合除 merge 重携外不相交；重携 id 先删后插净效果=leading
  版本获胜=全量构建语义（merged turn 是唯一持有者）。
- 预期：Mac older_page -8~12%（joined hash/find/compare ≈12.5% − COW 副本
  retain 成本 ≈2-3%）。
- 钉死：round-35 差分 harness 每步双折叠形态 presented 比较（Presentation
  Equatable 含 foldParents）自动覆盖 + **新增反盲断言**（至少一步
  foldParents 非空，防 fixture 无折叠导致钉死盲）+ merge 场景消费/重携
  顺序覆盖（场景 4/5 已有）。
