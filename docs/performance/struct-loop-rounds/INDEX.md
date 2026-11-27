# 正文性能结构优化循环：轮次索引

立项：用户 2026-11-27。定位="结构队列 + 场景级目标"：追求场景级 10x+，
100x 为拉伸目标、不作全线承诺。前序 20x 循环（round 1–46）按停止规则①于
2026-11-18 收尾，本循环处理其停止报告遗留的结构候选。

## 用户决定与授权（2026-11-27）

- A 定位：结构队列 + 场景级目标（非全线 100 倍）。
- B 红线解锁：**公开 API 与 AgentWorkbench 消费点改动已获授权**，限候选所需
  最小改动、外观零变化、功能回归钉死。20x 循环"不碰 Sources/AgentWorkbench"
  红线对本循环解除；其余红线继承。
- C 真机切换 1.3–1.6s 卡顿项**不纳入**（无需 perch-diagnostics.json）。
- D 零介入合并授权：每轮独立分支 `perf/struct-<N>-<日期>` + PR（标题
  `[perf-struct round N]`）；CI 全绿 + 评审闭环 + mergeable 确认后
  `gh pr merge --merge --delete-branch` 并在此记录。任何门槛不满足→不合并，
  留 PR 注明原因。禁止 merge 他人 PR、动主检出、碰用户真实数据/远端连接。
- E 不设预算，推进至完成条件或停止规则。

## 完成条件与停止规则

完成：队列每项以"带 A/B 证据的已合并 PR"或"记录在案的不采纳/缓议结论
（附原因）"结束；产出总结报告并更新本索引。

停止：① 连续三轮无超噪声可采纳收益→给剩余项附原因缓议结论、出总结报告后
停止；② 队列清空→停止并总结；③ 入口门槛不满足（无新 >2.5% 可攻点、插桩
下界未出）→该项缓议并记录，不硬做；④ Mac mini 或评审通道不可用→记录并
停止，不编造数据。

## 机制继承

测量与评审纪律继承 [20x-loop-rounds/INDEX.md](../20x-loop-rounds/INDEX.md)
机制节：单一假设最小修改；Mac 一对粗筛先行；基线/候选交替 A/B ≥6 对取中位
数，Mac mini 同机仲裁、超当轮实测噪声带才采纳；Linux 仅筛选、特有开销不计
产品收益；行为等价钉死（黄金摘要/差分模糊/变异电池）；否定清单反查
（20x INDEX「否定清单」节，勿重复尝试）；布局伪影家族披露口径；归因 harness
与采纳指标同构（输入规模/缓存命中分布/容器规模/分支短路负载/输入新鲜度）。
独立评审按 [REVIEW-CHANNEL-PROTOCOL.md](../20x-loop-rounds/REVIEW-CHANNEL-PROTOCOL.md)
（delegate_task target `{providerInstanceId: "acpRegistry_kimi_code",
model: "aone/gpt-6.1-sol"}`，只读共享检出；复核是新 delegate_task）。

测量环境：Linux=Alibaba Cloud Linux 3 x86_64，Swift 6.3.3 AL2，
`PATH=$HOME/.local/swift/6.3.3/usr/bin`。Mac=`ssh -o BatchMode=yes mac-mini`
（arm64，2026-11-27 验证可达）；GUI 作业走 PerfRunner：写
`~/Library/PerfRunner/jobs/<名>.job`，结果在 `~/Library/PerfRunner/results/`。
Mac 工作树 `~/_worktrees/20x-loop-20261112/perch`（round 2 停在 fda922fa，
用前 fetch+checkout 到本轮 base）；裸 swiftc 二进制被 SIGKILL，一律 SwiftPM
scratch 包。历史 A/B harness 在该工作树 `.local/`（ab-mine-all、base-all、
round31d 等）。

## 否定清单 / 方法学教训（本循环新增）

1. **计数器探针必须按调用相分类**（round-1 勘误）：共享 map 与空 map 调用
   混合平均可把超噪声机制稀释成亚噪声假象（44.4µs 拷贝被摊成 2.17µs，
   0.56% vs 真实 11.4%）。与 round-20 F3 归因同构家族同型，新维度=调用相
   分布。命名帧 inclusive 归因亦可能低估（memcpy 叶入 ARC/bridge 桶，
   HYPOTHESIS）——机制裁决靠隔离计时探针，不靠单一口径。
2. **PerfRunner 作业在所有工作树预建输出目录**（round-1 粗筛 v1 exit 1）；
   同名 job 不得在消费窗口内重发（round-31 教训继承）。
3. **release precondition 无消息**：钉死 trap 定位用 debug 构建（round-1
   两处 fixture/语义缺陷经 debug 消息定位）。
4. 20x 循环否定清单全部继承（见 ../20x-loop-rounds/INDEX.md「否定清单」），
   选题前反查。
5. **补丁重放须 tracked 还原 + untracked 清理双步**（round-1 门槛 v1 exit 1）：
   `git checkout -- <paths>` 不删未跟踪文件，遗留新文件使 `git apply` 报
   already exists；加 `git clean -fd <paths>`（gitignore 的 .local 不受影响）。
6. **本机对新 bundle ID app ~11s 准时 SIGKILL**（round-1 门槛 v2/v3 5/5 假失败；
   机制=异步首启评估/已知 ID 缓存为 **HYPOTHESIS**，与观测矩阵一致，未做
   指令级取证）：与启动方式（open/直接 exec）、重签深度、entitlements、执行
   上下文（SSH/Aqua LaunchAgent）均无关；同新 ID 复启仍死；已知 ID（acceptance
   fixture，20x 循环反复使用）存活。GUI 存活门槛须复用已知 bundle ID；
   生产入口门槛用原构建 + CFFIXED_USER_HOME/HOME 空目录隔离偏好域
   （hosts=[] → 零连接）。启动任何 app 前核验其偏好域无 hosts/远程连接配置。
7. **apply --check 须在派发 job 前做**（round-2 归因派发）：PerfRunner 秒级
   消费 job，派发后再 --check 会与 job 自身 apply 竞态→"patch does not
   apply" 假失败（树已被 job 打上补丁）。job 内 set -e 自保，无实害；
   核验顺序=scp 补丁→远端 --check→再 scp job。
8. **Swift `Array ==` 只在两侧共享同一 buffer 时跳过元素比较**（round-2 shard A
   变异电池 M4 首次存活）：`first == second` 若两个数组来自同一 Snapshot，元素级
   `==` 根本不执行，"不得触发求值"的 pin 会假通过。懒/延迟求值类的反射 pin 必须
   构造**不同 buffer 持有相同实例**的数组（`flatMap { [$0] }`、或 delta 前后的新旧
   navigation），才等于生产里的比较形状。
9. **懒化候选必须走查"值相等即求值"的消费点**（round-2 shard A BLOCKING 发现）：
   `Equatable` 的 `@Published` 快照每次 viewport refresh 都比较一次，值相等语义会
   把延迟成本搬到滚动路径（**限定**：并非任何纯刷新都触发——首发时旧导航为空、其后不变的刷新与上次
    共享同一数组 buffer 被 `Array ==` 跳过；真实形状是尾 delta 等产生新 buffer 但共享历史实例后的
    那次 refresh，以及 language/epoch/online 重建后的等值比较）。修法=元素级 `==` 加 `lhs === rhs` 反射短路（不改变
   Equatable 语义），并用第 8 条的形状钉死。凡引入懒/引用类型，先 grep 所有
   `Equatable`/`@Published`/`onChange`/`.task(id:)` 消费点。
10. **非交替的 A/B 会把机器漂移记到候选头上**（round-2 shard A mounted 复测）：
    base 全部跑完再跑 cand 时 `session_switch_ms` 出现 +38% 假差异；`switching`
    4 轮交替时仍有 3 轮 cand 偏高 +18%，扩到 **10 轮交替**后配对差中位仅 +0.8%、
    符号 5 正 5 负，且 4 个异常轮两侧都出现（cand 3 / base 1）并伴随
    `main_actor_lateness.max` 563–765ms 系统尖峰。结论：GUI 侧指标一律交替，
    轮数要到配对差中位远小于轮间带宽（本例 0.8% vs 21.6%）才可判定；
    单看 2–4 轮的"一致偏高"可能是尖峰分布不均。
12. **mounted 冷首访验收必须自证"冷"，夹具规模就是验收口径的一部分**（round-2 shard A 评审 B2）：200-turn + 8-model LRU 的 acceptance 切换里 80 次有 72 次是暖恢复（`preparations=8`/`restorations=72`），不能当冷首访。做法=把会话放大到超过缓存准入上限（1000 条/1MiB）使每次挂载结构性冷，并把 `restorations==0` 作为运行时自证写进 harness；**mount 与 rail 发布拆成两个计时边界**；settle 条件不要依赖可能不等的标识字符串（v1 因等 `navigator.snapshot.session` 两侧同样 5s 超时，白跑一轮）。
11. **CI 的 acceptance 时长门槛在共享 runner 上会假失败**（round-2 shard A）：
    `native-dashboard` 本机 41–46s，CI attempt 1 跑到 134.99s 撞 120s 上限失败，
    未改一行代码 rerun 即 15/15 全绿。判 flake 的证据链=本机两侧同量级 +
    base 同 job 历史 success + rerun 通过；不要据此改候选或放宽门槛。

## 候选队列

| # | 候选 | 状态 | 依据 |
| --- | --- | --- | --- |
| ① | 大会话冷首访懒/视口投影 | **shard A（懒导航）已验证**（PR #380；最终 head 模型层 16k 冷 −52.90%/2.117× 6/6 超带、mounted 冷首访 −11.67% 7 轮交替 6/7 超带；评审两轮：第一轮 2 BLOCKING（B1 等值重建全窗求值→`sameNavigation` 策略修复；B2 mounted 冷首访缺口→新增 `struct-cold` 模式补齐）、第二轮 **0 BLOCKING / 6 NONBLOCKING 全部处置**；生产门槛 5/5、portable 12/12）；**已合并 merge=`efe23dd5`（PR #380，2026-11-27 21:09，`--merge --delete-branch`，分支已删；CI 15/15 一次通过）**；**shard B（真 per-turn 懒物化）已缓议（不采纳）**：成本侧已实测、收益侧未获 A/B，**当前没有满足 §9 双边界的采纳证据**：单次结构变更 `reconcileRows` 实测 **C≈10.0ms@16,000 行**，而物化必然改变行数 ⇒ 每批一次 O(窗口) reconcile；**清算（评审 B1 更正后，现行收据 `breakeven-v3-discrete.txt`）**：本行初版写的「净收益在批量 <5000 turn 时全为负、全局最优（冷访即物化 75%）也只 +0.77ms、低于可测分辨率」**已明确撤回**——它用 `(8000−B)/B` 允许**分数次** reconcile，而批次数是离散的 `ceil(8000/B) − 1`，B=6000 时剩余 2000 turn 仍须付一整次 ≈9.4ms ⇒ 净值 **−5.48ms 而非 +0.78ms**；「B<5000 全为负」在旧的连续放松下也不成立（B=4800 已 +0.24ms）。更正后：批量方案 (a) 在离散清算下对 **mid/post 定价**的所有 B<8000 净值为负，但 **pre 定价在 B=4000..4116 为正（最大 +0.30ms）**，故该结论**不能泛化到三种定价**（**模型值、非实测净亏**；且本轮**未做全文滚动 A/B**，故 §9 判据 2 属**未评估**而非已判失败），增量 splice (b) 未被否证，但须改 `indices`/`geometry.offsets` 表示或走 `O(n−i+k)` 线性增量路径且冷边界上限仍是未证实的 15.6ms（见 round-4 行与仓外设计稿 §11）；其"结构/内容相拆分"支线（A1）另经 round-4 分相实测加固缓议：Mac 主导相位是 B 分类分组 62.4%，A 内容检视仅 22.9%，而**同档位** Linux debug 的 A 相为 78.0–79.4%（16k 档，归档日志 `linux-debug-timeline-make-2k-16k.log`）⇒ `trimmingCharacters` 为 corelibs 特有开销 | Mac 63.73ms@16k；turns 83.8%；大会话每次重访 100% 冷（Linux+Mac 运行时证实），占切换成本 ~100%；**nav-split（同跑口径）：Mac summary 53.07%（34.088/64.23）/timeline 22.4%/rows 2.0%，Linux timeline 57.8%/summary 32.7%（主导跨平台翻转，全懒边界平台无关）；旧 54.6% 混用跨 job 分母已勘误**；契约 5 项钉死（查找扫源消息天然独立；几何纯值类型为估高接缝；~~跳转列表展开同步物化~~ **该旧方案已撤回**：shard A 落地后产品无一次性全窗展开触发面——rail 只画刻度、hover 预览与 accessibilityValue 各读 1 条、bookmarks 菜单只读已收藏项且正常 toggle 路径上限 50） |
| ② | foldParents 整字典 COW 消除（split 表示，API 形态） | **已合并 60420b1a（2026-11-27）** | v2 探针翻盘：拷贝 44.4µs@16k / 308.7µs@64k，chain 份额 11.4%/17.4%；B 授权解锁；正式 16k chain -12.1%/presented -63.3%（6 对）；64k 三对缩放佐证 chain -28.9%/presented -83.9% + v2 独立重建佐证 3 对全负超带 median -30.4% |
| ③ | displayMessages / Array.+ API 形态决策 | **缓议（不采纳）**——本项指向的拼接份额低于入口门槛，已有裁决与证据，不再待立项（状态栏与本行依据、`REPORT.md` §3 同步） | round-38/42 遗留；Array.+ 8.58% inclusive；64k chain 残余嫌疑=`Snapshot.rows` getter :399 `history.rows+tail` 与 presented :453 `earlier.rows+rows` 每 delta 两次 O(窗口) 拼接（displayed() 空 activity 已有快路径）；②采纳后 64k chain 残余实测 1.09–1.20ms（formal cand，median 1.13）待归因探针定量 |
| ④ | 验证族路径插桩 → **已插桩裁决，转记为「分页 prepend 验证去重」候选** | **冷首访净下界 = 0，缓议**；**prepend 相位上限 14.98%**（Linux 整个 retained 相位的宽泛上限，**尚未满足入口门槛**：门槛要求 Mac 同跑**净下界 > 2.5%**，相位上限与排序都不能替代）→ 记为**待证明候选**，排在 shard B 之后；**§6.1 重复 bitwise 扫描 = 缓议**（Mac 6 对交替 A/B **未检出超出噪声带的可采纳净收益**；同场景 2.5% 门槛在该批数据下**不可判**）⇒ **④ 全部收口**（round 4） | round-3 P1 计数探针（`verify-probe.patch` sha256 `f484e178…`，tests-only 未提交；Linux release 16k：cold `sameWindow` **零调用**、costReuse 18,667 次迭代**零比较**、重算 18,667 次 ⇒ 冷路径 retained 全是**成本计算**不是验证，属 shard B 的 B-2 retained 上界化范围；delta retained 9µs（0.358ms 的 2.51%）；**prepend** costReuse 比较 18,668 次全命中、重算仅 2 次，而 TV 侧 7,999 次 chunk `sameWindow` **全部 bitwise 命中**，bitwise⇒value，故**仅在被 chunk 证明覆盖的 `[2,18666)` 那 18,664 条范围内**逐条 `==` 可省（4 条 tail 不在任何证明内，必须保留原比较；`shift` 只定位旧首消息 id，不证明后续位置全对齐），retained 2.394/total 15.986ms = **14.98%**，cold 2.29%、delta 2.51%/9µs）。**该 14.98% 只是整个 retained 相位的宽泛上限，不是已证明的可转化份额**（评审 B2）：相位内还含 costs 数组构建/append/reduce/live-tool 成本/`previous = input` 旧窗释放；且 chunk 的 bitwise 证明只覆盖 18,664 条，cost 比较覆盖 18,668 条，**4 条 tail 不在证明内**；`shift` 仅查找旧首消息 id，**不证明后续位置全部对齐** → 候选须逐范围绑定证明、其余保留原比较。另：`sameSearchableWindow` 先 `sameWindowBits` 再 `sameWindow`（内部又扫一次 bits）的重复扫描，find_warm 实测仅 1 个元素，**但同批 16k find_cold 有 2333 个重复元素**——harness 先跑 2k 未清共享缓存；round-4 补测（探针 v2，每尺寸前清三个共享缓存）证实该 2333 确系污染（清缓存后 find_cold 的 searchable 调用 **0**），而 **find_redecode / find_nfd 的重复 bitwise 扫描覆盖整窗 18,667 元素**、find_after_prepend 8,000 单元素，五场景 `hits` 全等（16k 39,999 / 2k 5,001）。消重候选（`sameWindowValues` 提取，`sameSearchableWindow = bits || (values && rendered)`，真值表逐项相同；tests-only 未提交）经 **Mac 6 对交替 A/B** 裁决：**12 个场景比较无一超自己的噪声带**，且零重复场景（find_cold/find_nfd_cold，Δ −0.15%/+0.91%@16k）与整窗重复场景（find_redecode/find_nfd，Δ −0.41%/+0.43%@16k）**变动同级**（该对照**只作佐证**，不构成「若有效应必分开」的证明）。**口径已按评审 B3 更正**：撤回初版的「低于测量分辨率／绝对上界 ±0.59ms／相对冷搜索 ≤0.03%」——`(max−min)/median` 是**采纳标尺**、不是计时误差界或纯 memcmp 成本上界，且受影响场景（re-decode）分母是 ~7.49ms、样本全距 `0.589ms` 即 **7.86%**，**不能换用冷搜索分母**去认证**同场景** 2.5% 门槛 ⇒ 该门槛在本批数据下**不可判**。缓议依据只剩「**本批未建立超出噪声带、可采纳的净收益**」；零重复场景与整窗重复场景变动同级**只作佐证**。⇒ **§6.1 缓议，④ 全部收口**（冷首访净下界 0 / §6.1 未检出超带净收益 / prepend 残余仍为待证明候选、三项前置未满足）。立项前三项前置（缺一不立项）：(a) **逐范围 soundness 论证**——chunk 的 bitwise 证明如何与 cost 循环 `index - shift` 绑定，未被证明覆盖的范围保留原比较，含 `Chunk.source` 等值窗口收养的影响；(b) **Mac 同构时间归因**——Linux 份额只是提示，产品收益须在 Mac 以同构 harness 复测 prepend 场景；(c) **净下界计算**——按 P3 扣除绑定检查/memo 自身开销与收养失效率后仍需 **> 2.5%（Mac 同跑口径）**，不足即缓议归档，**不得以 Linux 相位上限替代**。采纳另需 ≥6 对交替 A/B。**本轮勘误（评审 B1，BLOCKING）**：初版引用的 6.454/294.333、0.013/0.459、2.825/16.633（17.0%）出自一次**未归档**的试跑，已全部改为归档日志 `linux-release-2k-16k.log` 的逐字值 |
| ⑥ | `sameNavigation` 共享连续存储短路（round-2 评审 N4） | 缓议/建议并入 shard B 轮 | 已定量：8000 turn 下 ≈35µs/次刷新（同/异 buffer 0.03475/0.03621ms），不物化摘要；占滚动步 ~0.4%、帧预算 ~0.2%，单独看低于 2.5% 入口门槛；改它会动 WorkbenchCore 产品字节使本轮采纳批失效，故不在本轮做。shard B 会重写这条判变路径，届时一并处理 |
| ⑤ | 冷首搜 cf-match 调度层（语义不动，改时机/范围） | **设计评审已返回：`需修改后再审` ⇒ 缓议、不立项**（round 4） | 指定模型评审（thread `mcp:ad9ba599…`，完整回复 `_evidence/…/round4-review-20261127/review-queue5-design-final.txt`）。**方向 A** 五项送审问题全部 BLOCKING——须限定**完整 entry 为原子**（`search()` 逐 entry 独立匹配、不存在跨 entry 命中 ⇒ 重叠窗为 0、不需归并去重；但 entry 内多 source 以换行连接，匹配与 excerpt 可跨 source，故切行/切 part 时任意长度多行正则与锚点**无通用有限重叠窗解法**，也不能按 `hit.id` 去重而改变出现次数）；归并键应为 `(全局 entry 序号, entry 内匹配序号)`——现有顺序是 prefix→suffix→各自 timeline 的 entry 序→entry 内原枚举序，且匹配范围是 **UTF-16 `NSRange` 而非 UTF-8 字节偏移**，公开 hit 无 offset 字段、只有 `entryID/occurrence/excerpt/toolID/toolOccurrence`（两个 occurrence 计数语义须原样保留）；须**先按原算法生成 prefix/suffix timeline 再分配完整 entry**，不得对每块重新调用 `make()`（分组、相邻 assistant part 合并、`partOffset`、running 状态都影响 entry 身份/表示），并保留逐 source parse、换行连接、`sourceEnds` 与 composed-character excerpt 扩展，不新增 NFC 化/大小写预折叠；块只是临时执行单元、**不是新增缓存分片**，不得每 worker 各开一套默认预算、不得把部分 prefix 当完整节点入表，且 window/payload 与 entry/prefix 之间的**保守双重计数是既定约定、不能借分块去掉**，缓存提交宜由单 owner 按原 entry 顺序完成以免完成顺序改变 LRU 行为，worker 输入/ranges/结果副本/取消后留存属额外峰值内存须实测；`ConversationSearch` 是持有可变 `entries/earlier` 的同步对象、**matcher 内没有取消检查**（find bar 同步直调；history worker 虽在后台 actor 上执行，外层只在返回后拒绝旧结果）⇒ 须先定单 owner、受限并发池、请求身份（session/host、源窗口版本、查询字节、options、running、失效世代）与取消契约，UI 只在主 actor 发布一次完整结果、不得在主 actor 同步等待并行组，且**不得许诺任意长 entry/正则的硬实时抢占**。**方向 B 不按「已覆盖所以零收益」否决**：`rendered_calls=0` 记录的是 `sameRenderedMessages` **验证层**调用、**不是** `RenderedSourceCache.rendered()` 的 lookup/hit/miss/produce；冷首搜清空三个共享缓存后无旧结果可验证，随后仍走 sources 构造、渲染缓存、连接与匹配 ⇒ 本轮日志没有渲染缓存命中率或文本准备时间，**不能称文本准备已全覆盖**，须先量残余文本准备与前移成本（B 属工作前移，须同时计挂载、空闲预热、无搜索时的浪费、失效重做与驻留）。**方向 C 否决确认成立**（违反红线 3 与查找契约 2；「完整集」指本次搜索既有、已披露的源消息窗口，不是可见/物化子集；既有 loaded/full-history 范围披露不构成进一步按视口缩小的授权；「优先视口但等全窗完成才发布」可保持契约，但那是调度而非范围削减；NONBLOCKING：删除「只有 shard B 落地后才能重评」这一过时条件——渐进匹配不依赖懒物化）。**入口门槛未满足（BLOCKING）**：历史 cf-match 79% 是**有归档、经复算**的历史证据（性质不同于 round-3 B1 的未归档试跑，不应混为一谈），但它**混合了 source 准备中的 DataDetectors 与真正的 CF 查询匹配**、跨 harness 迁移且份额≠可转化量 ⇒ **不能直接充当本循环 >2.5% 的可攻净下界**；本轮 16k 冷首搜 2155.871/2171.062ms、warm 0.366/0.410ms、redecode 7.471/7.369ms 只证明「冷窗口值得关注、复用路径不再是主战场」，**~1700ms 只是旧份额×新墙钟的估算，不是本轮 cf-match 实测、更不是净下界**；按该墙钟 **2.5% ≈ 54ms**，须证明保守净值**严格大于**它（2.5% 是入口门，采纳仍需正式 A/B 超当轮噪声带）。立项前须先补四项测量：①同构分相归因（冻结 base/harness/hash/规模/查询/缓存制度与原始样本，区分文本准备与 DD 同查询匹配，记录 source 唯一数与 hit/miss，五层最小口径，判据=分相对账闭合、不重复归属）；②完整 entry 的 K 调度可行性（tests-only 载体执行真实调用，量块耗时、最大 entry、并发重复工作、锁、传递与归并，补 CJK/Unicode、regex、无命中与密集命中形态，判据=旧 oracle 有序字节/range 零失配且保守净下界 >2.5%）；③取消与生命周期前测（不可抢占调用最长耗时、取消→退场/释放、重试等待、反序晚返回，判据=零旧请求发布、零部分缓存冒充完成、取消尾成本明确且不能靠截断源窗口过关）；④内存与成本搬迁账（A 量并发峰值与取消留存；B 若继续另量挂载/空闲预热、首次搜索、无搜索浪费与失效重做，判据=原预算/准入不变、无未入账留存、移出成本完整披露）。§4 测量计划另需补：**独立冻结的旧单线程算法 oracle**（比完整**有序序列**而非集合或 hit 数，覆盖所有 hit 字段，测试载体内比 UTF-16 ranges、`sourceEnds`、tool 路由；`K=1` 的新实现**不能**代替旧算法 oracle）；**调度/取消对抗**（强制反序完成，在块中途/归并前/发布前取消，覆盖查询与 options 替换、session 替换、分页、历史同 ID 编辑、running/locale 变化、晚返回与重试，四制度 × `K∈{1,2,4,8}` 交叉）；**「render 暖、结果冷」制度**（改一个查询字符会使 prefix/entry 结果键整体失效，**不是**前缀缓存部分命中，主要只剩 rendered-source 复用）；**真实到达边界**（查询提交→完整计数/excerpt 发布，以及首次 reveal、折叠展开、工具定位与冷 host 工作，不能只测同步 search bracket）；**方差不能只写一句**（每个 K 保留原始 run、样本量、统计量、双侧噪声与尾延迟；现有两 run 只确认绝对量级，不足以建立并行噪声模型）。**若继续 ⑤，只做第①项（同构分相归因）**，据其结果决定立项或永久缓议，不得跳过它直接实现并行匹配。**与已合并成果无冲突**（评审确认）：限定在「源消息→完整 entry」搜索路径内不需改 shard A 或 ②，但 worker **不得持有或读取** shard A 的非 Sendable、会物化的 summary 引用对象，`sameNavigation` 的非物化判变策略与 ② 的 base+overlay、overlay-wins 及收养/折叠映射保持不动，hit 的 entryID/tool 路由不变、reveal 继续消费现有映射，⑤ 自身既有的消息副本收养也要保留（不能让旧 worker 覆盖新请求状态）；**①B 缓议已解除「⑤ 须排在 ①B 之后」的耦合**（当前无未物化 turn、不需 reveal 物化同步点，风险面减少），但线程/取消/缓存/冷 host reveal 风险仍在且**不因此豁免入口门槛**；④ 已收口 ⇒ ⑤ 须独立派发，可在同一个 ⑤ 归因作业内同时回答 A 与 B 的份额问题。详见仓外任务目录 `queue5-cf-match-design.md` §6 |

## 轮次记录

| 轮 | 日期 | 场景 | 结论 | 报告 |
| --- | --- | --- | --- | --- |
| 1 | 2026-11-27 | ② foldParents COW：探针翻盘 + split 候选 | 候选 e40b7054；Linux 113 PASS+1 SKIP、portable、变异电池 4/4；粗筛 v2 通过；**16k 正式 PASS**（6 对 chain -12.1%/presented -63.3%，全负、中位数超带）；64k 三对缩放佐证（chain -28.9%/presented -83.9%，全对超带）+ v2 独立重建佐证 3 对（median -30.4%，全负超带）；**采纳**；评审两轮闭环（0 BLOCKING）；生产门槛 v5 5/5、fixture 门槛 v4 5/5 独立登记；PR [#378](https://github.com/chenweigao/perch/pull/378) **已合并 60420b1a**（复核 0 BLOCKING，CI 15/15，分支已删） | [round-1](2026-11-27-round-1.md) |
| 3 | 2026-11-27 | ④ 验证族插桩裁决（归因轮，零产品字节） | 探针 `verify-probe.patch`（sha256 `f484e178…`，tests-only 未提交）计数 16k：**cold `sameWindow` 零调用、costReuse 18,667 次迭代零比较**（`previous==nil` 全部重算）⇒ 冷路径 retained 全是成本计算而非验证，**④ 对核心目标净下界 = 0 → 缓议**；delta retained 9µs；**prepend** costReuse 比较 18,668 次全命中/重算 2 次，TV 侧 7,999 次 chunk `sameWindow` 全 bitwise 命中，retained 2.394/total 15.986ms = **14.98%（Linux 相位宽泛上限，非 Mac 净值）** → 记为**待证明候选**，三项前置（逐范围 soundness 绑定 `index-shift`／Mac 同构归因／净下界 >2.5%）缺一不立项，排在 shard B 之后；`sameSearchableWindow` 重复 bitwise 扫描 find_warm 仅 1 元素但同批 16k find_cold 有 2333（harness 未清共享缓存）→ **改判未决**，须补三场景。**（§6.1 已于 round 4 补测三场景并裁决为缓议，见 round-4 行；本行保留为 round-3 当时的记录，不改写。）**三轮独立评审（2B+2N → 2B+1N → **0B+1N**）全部处置；portable 12/12；CI 15/15；**已合并 merge=`c26c8817`（2026-11-27 22:31，分支已删）** | 设计与裁决全文在**仓外**任务目录 `~/code/docs/2026-11-27-perch-body-performance-loop/queue4-verification-probe-design.md`（探针补丁与原始日志在同任务目录的 `~/code/_evidence/perch-body-performance-loop-20261127/round3-verify-probe-20261127/`），不入仓以免把执行器私有路径写进公开仓库 |
| 4 | 2026-11-27（评审处置 11-28） | 归因/裁决轮：`ConversationTimelineEntry.make` 分相 + ④§6.1 消重 A/B + shard B 成本边界（**零产品字节**） | **(1) make 分相**（job `struct-4-timeline-make-20261127`，Mac release 3 轮 16k，补丁 `timeline-make-probe.patch` sha256 `a26e54d1…`，tests-only 未提交、跑后 porcelain 空）：`make_total` 14.832/14.979/14.934ms（与 round-2 nav-split 的 timeline 相位 14.412ms 差 3.6%，**仅作量级交叉检查**，不等同于"插桩未放大被测相位"的证明——那需要校准实验，本轮未做）；相位 **B 分类+分组合并 62.4%**、A 内容检视 22.9%、coalesce 0.9%、未归属 **13.77%**（中位；逐次 15.89/13.77/13.77%）；探针含 make/A/B/coalesce 四组计时，16k 下约 **64k 次**时钟读取且 A 相内含计数器写入，故 A/B 份额是**含探针开销口径下的观测值**（称"严格下界"需校准实验支持，本轮不作该断言）。**最小子集**（全窗一次性构建"源消息 id 集合 + tool call id 集合"）0.587ms（三值为 min/median/max，非 run0/1/2）= `make` 的 **3.930628%**，满足 §6.3 的 **<30% 筛选条件**；**但这是筛选、不是净下界证明**（round-4 评审 B2，BLOCKING，已采纳）：实测的是全窗循环外的一次性 Set 构建，**不是**每 turn 两个索引及其分组/分配/持有成本，故**未给出完整方案开销的上界**，正确表述为"最小集合构建成本筛选通过；完整同构成本与成员判定等价性仍待证明"。跨平台对照（**同档位、已归档**）：16k 档 Linux debug A 相 **79.38/77.95/78.02%**（make_total 349.711/351.284/351.052ms）vs Mac release **22.9%**；2k 档 Linux 78.80/88.92/88.76% vs Mac 48.0–48.2%（**Mac 2k 首跑为 24.08%，该区间只覆盖后两跑**）⇒ A 相的 `trimmingCharacters` 是 corelibs 特有开销（20x round-18 已三次否决），**A1「结构/内容相拆分」缓议被实测加固**，只有 A2（整段不跑 `make`）能拿到那 62.4%。最小子集份额两平台均远低于 30%：Mac 16k **3.93%**（约束值）、Linux debug 16k 1.77%（6.198/351.052）、2k 1.48%；探针在位时 Linux debug 套件 **114 PASS + 1 SKIP + 0 FAIL**（行为中性）。**勘误一（本轮自查）**：初版引用的「Linux debug A 相 88.8%」出自 **2k 档一次未归档试跑**却与 Mac **16k 档** 22.9% 对照（档位不匹配 + 证据未归档，与 round-3 评审 B1 同类），已补跑同档位两档并归档、以逐字值替换；原试跑样本**已不可得、予以撤回**，补跑的是**新样本**而非把原样本补归档。**勘误二（评审 B5，BLOCKING）**：仓外 §8 曾引用 Linux debug 的 `find_redecode 9.19ms@2k`/`find_cold 392.6ms` 作量级指示，但**无归档收据**（已归档 Linux 搜索日志只有计数、`grep -c search_wall_ms` = 0）⇒ **已撤回、不得用于裁决**，份额一律改由已归档的 Mac release 计时裁决。**(2) ④§6.1 收口**：探针 v2（sha256 `513e9602…`，每个冷场景前清 EntryCache/PrefixCache/RenderedSourceCache）证 round-3 的 `find_cold=2333` 是 2k 预热污染（清缓存后 searchable 调用 **0**），但 find_redecode/find_nfd 的重复 bitwise 扫描覆盖**整窗 18,667 元素**、find_after_prepend 8,000 单元素；Mac 绝对计时（job `struct-4-search-scenarios-20261127`）：16k find_cold 2155.871/2171.062ms、find_warm 0.366/0.410、find_redecode 7.471/7.369、find_after_prepend 63.739/63.729、find_nfd 2190.503/2193.856。消重候选（`search-dedup-on-probe.patch` sha256 `1f83f089…`，35 行，**tests-only 未提交、不作成果**）真值表逐项相同（含空窗/长度不等边界，评审独立复核确认）；计数等价：12 次运行的 `hits`/`value_elements`/`rendered_*`/`searchable_bits_hits`/`bitsOnly_calls,elements` 逐值相同，cand 归零的是**四个**字段（`sameWindow_calls`/`sameWindow_elements`/`bits_misses`/`searchable_duplicate_elements`）；两侧 Mac release 各 **115 PASS / rc=0**。**Mac 6 对交替 A/B**（job `struct-4-dedup-ab2-20261127`，base 二进制 `246058b7…` / cand `aafaabd3…`，每变体一个 worktree 就地运行）：**12 个场景比较的逐对中位变化均未超 base 侧噪声带**，72 个配对差仅 3 个单对超带且方向均"混合"。**裁决口径（评审 B3，BLOCKING，已采纳）**：这只足以支持"**本批未建立超出噪声带、可采纳的净收益**"⇒ 按 TASK 采纳规则**缓议**；**撤回**初版的"决定性证明""绝对上界 ±0.59ms""≤0.03% of 冷搜索"——`(max−min)/median` 是**采纳标尺**而非计时误差界或纯 memcmp 成本上界，且受影响场景（re-decode）的分母是 ~7.49ms（样本全距 `7.664−7.075=0.589ms`，即 **7.86%**），**不能换用冷搜索的分母**去认证**同场景**的 2.5% 门槛 ⇒ 该门槛在本批数据下**不可判**（既未证低于也未证高于）。零重复场景（find_cold/find_nfd_cold，Δ −0.15%/+0.91%@16k）与整窗重复场景（find_redecode/find_nfd，Δ −0.41%/+0.43%）百分比同级**只作佐证**，不构成"若有效应必分开"的证明。投影侧 cold/delta/prepend 控制场景的**已归档观测收据是 Linux debug 两侧**（Mac job 只 grep 了 find 场景，故 Mac raw log 不含该配对行）；另按既有口径：`hits` 是数量非输出 hit 集，窗口长度计数 ≠ memcmp 实际读取字节量。**(3) shard B 成本边界**（§9 判据 2 的前置必答，job `struct-4-reconcile-cost-20261127`，exit=0、`behavior_passed=true`、porcelain 空；补丁 `struct-cold-harness-v3-reconcile.patch` sha256 `245a8ff3…`，**185 行新增/4 行删除**，tests-only；acceptance 构建 release -O + `PERCH_ACCEPTANCE`/`TRANSCRIPT_CHECKS`，app sha256 `081bce95…`，`build.json` commit=`c26c8817`/source_sha256=`19ba4587…`）：探针照既有 `checkReconciliation()` 写法构造合成行并**直接调用真实 `reconcileRows`**（绕开 `configure` 的 identity 快路径），2 run × 5 round × 3 形状 = 每形状 10 样本 ⇒ **C ≈ 10.0ms @ 16,000 行**（middle_1 11.036/11.012、middle_8 10.018/10.267、end_1 9.900/10.207ms；**全距/中位 = 6.45%/9.48%/12.82%**）。自校验与其边界：产品自带 `document_reconcile` stage 计时与外部墙钟逐次最大差 **≈0.008ms**（成本确在 `reconcileRows` 内）；插 1 行≈插 8 行、中部≈末尾、insert≈restore ⇒ 支持"存在与插入规模/位置无关的共同整窗成本"，**但 O(窗口) 的渐近结论主要来自源码**（两张整窗字典重建 + `heights` 整窗 map + `rebuildOffsets`），本轮未测其他窗口规模、未做相位独占归因；**`end_1` 并未测到等值 guard 的最坏早停**（三个形状都改变行数，`structureChanged` 在 `contents.count != next.count` 处即短路，id `zip` 根本不执行）。**C 是下界**（未含 `configure` 的 publishHeight/refreshVisibleRows/restoreReadingPosition），且**只是 16,000 行这一规模的观测值，不是所有较小窗口的统一下界**。**清算（评审 B1，BLOCKING，已按离散模型重算）**：初版用 `(8000−B)/B` 允许**分数次** reconcile，是错误的——读完全文的新增批次数应为 **`ceil(8000/B) − 1`**；B=6000 时剩余 2000 turn 仍须付**一整次** ≈9.375ms，故净值为 **−5.48ms 而非 +0.78ms**，"+0.77ms 全局最优"**已撤回**；且即使在旧的连续放松下，修正模型在 B=4800 已为 +0.24ms，故"B<5000 全为负"**也不成立、一并撤回**。离散模型下合计净值**（限定定价口径）**：**mid/post 定价**下合计净值对所有 B<8000 为负（整数 B 全域扫描 1..8000），但 **pre 定价在 B=4000..4116 为正（最大 +0.30ms）**，故该结论**不能泛化到三种定价**；B=8000 即 eager 本身，三者均为 0。**这些都是模型值、不是实测净亏**，且 C 的行数线性定价**未经其他规模验证**（现行收据 `breakeven-v3-discrete.txt`，已按半进位重出：B=6000 净值 pre/mid/post = −4.85/−5.48/−6.10ms，B=400 判据 2 新增成本 159.70ms；`breakeven.txt`/`breakeven-rowcount-corrected.txt`/`breakeven-v2-discrete.txt` 均已被取代）。更关键的是 **§9 是两个分别验收的条件，不是一个允许冷收益抵扣滚动回归的合计净值**：全文滚动时 A2 还要吸收**延期过来的 timeline/rows 工作本身**（eager 在冷访已付清），故判据 2 的新增成本 = 延期工作 + reconcile 合计（B=100 时 ~610ms、B=7000 时 ~11.6ms）。**本轮没有做全文滚动 A/B**，且滚动墙钟由逐行挂载/测高/文本渲染主导（量级与 10–16ms 不同阶），故**判据 2 处于「未评估」状态，不得写成「已被实测判失败」**；用 mount(~172ms)、冷搜索(~2200ms) 或另一指标 `scroll_step` 的 30.51% 带来论证"本指标 +0.77ms 不可测"**不成立，已撤回**。⇒ **①B 缓议（不采纳）**，理由为"**当前没有满足 §9 双边界的采纳证据 + 成本风险高 + 后备路径未立项**"，而**非**"实测否证所有批量大小"。后备路径评审亦指出**未被否证**：不改稠密表示也可做 **`O(n−i+k)` 线性增量 splice**（替换 contents/heights 受影响范围、更新后缀 `indices`、对后缀 `offsets` 加高度差，避免两张整窗字典从零重建），**能否靠常数改善达门槛未测**；"占位行原地长高、行数不变"需重做 entry-id 查找/折叠/行内锚点，且既有 `updateHeight` 仍重建整窗 offsets，非无代价；"只承诺冷首访单边界"是**产品口径改变、须用户拍板**。复活条件（形式可判）：(i) 行几何次线性化**或**实现上述线性增量路径，**且** (ii) 重测 C 达 **≲0.5ms@16k 行**（该 0.5ms 是**设计目标值、非本轮推导的实证阈值**）；或 (iii) 产品显式接受单边界口径。任一满足后仍须重走 §9 双边界验收（含**全文滚动 A/B**）与 §4 七项变异电池。**本轮不宣称任何收益**：15.6ms 始终是算术外推，只测到了成本侧。**停止规则计数仍为 0**（归因/裁决轮，按 TASK §10 不计入无收益候选轮）。**环境事实（已复现）**：`.build/release/WorkbenchChecks` 的逐字节副本在别处 exec 会被 **SIGKILL（rc=137、零输出）**——`codesign --verify` 报 valid、`--force --sign -` 重签仍被杀、`otool -L` 无任何 `@rpath` 依赖、`cmp` 证明与可运行的树内二进制相同，原因未查明 ⇒ 一律按 round-2 先例"每变体一个 worktree、就地运行自己的 `.build/release/<product>`"（attempt 1 因此作废） | 设计与裁决全文在**仓外**任务目录 `~/code/docs/2026-11-27-perch-body-performance-loop/`：`shardB-A2-design.md` §10–§11、`queue4-verification-probe-design.md` §8–§9、`queue5-cf-match-design.md` §6；原始日志、补丁、sha256、离散清算脚本（**现行收据 `breakeven-v3-discrete.txt`**；`breakeven.txt`、`breakeven-rowcount-corrected.txt`、`breakeven-v2-discrete.txt` 均已被取代、仅留作过程记录）与 portable 收据（**目录名随最终 head 变化，形如 `portable-<该 head 前 8 位>/`；只保留最终 head 的一份，前序 head 的收据目录在每次 head 前进后即删除**，以免留下与最终 head 不匹配的收据——本行刻意不写死具体 SHA，避免每次补引用都产生新 head）在 `~/code/_evidence/perch-body-performance-loop-20261127/round4-{timeline-make,search-scenarios,search-dedup,reconcile-cost,review}-20261127/`（不入仓以免把执行器私有路径写进公开仓库）。**本轮独立评审（head `e159ffbb`）返回 `VERDICT: FINDINGS`（5 BLOCKING B1–B5 + 多项 NONBLOCKING），本行即为处置后的版本** |
| 2 | 2026-11-27 | ① 冷首访懒物化：盘点+契约+nav-split+**shard A 验证采纳并合并 `efe23dd5`** | 基线 63.73ms@16k、turns 83.8%、触发 100% 冷；契约钉死版立；nav-split 裁决 summary 主导 Mac 冷路径（**同跑口径 53.1%**，旧 54.6% 混用分母已勘误）；**shard A 懒导航：审查发现 `Equatable` 快照每次 viewport refresh 值比较会全窗物化（BLOCKING），加 `==` 身份短路修复；Mac 6 对交替 16k 冷 67.480→31.916ms（−52.86%，2.11×，6/6 超带 2.87%），2k −61.74%；延期成本 34.03ms 全量物化（与 nav-split summary 相位 34.088ms 差 0.2%）、单条 hover +9µs、无一次性全量触发面；footprint −3.4%、进程峰值 RSS −1.9%；delta/prepend 无回归；Linux 114 PASS+1 SKIP、变异电池 6/6、UTF-8 字节 oracle；生产门槛 5/5、acceptance paging/switching/dashboard 全 passed（switching 10 轮交替配对差中位 +0.8%，符号 5/5）；CI 15/15；独立评审第一轮 FINDINGS 2 BLOCKING → **B1 已修**（等值重建仍全窗求值：language/epoch 重置与 online 翻转重建全部实例、值比较两侧各物化一次；改为 Core `sameNavigation` 单一判变策略，电池 8/8）、**B2 已补**（tests-only `struct-cold` 模式：8000 turn 超缓存准入 → `restorations=[0,0,0]` 自证结构性冷；mounted 冷首访 201.128→175.475ms（−11.67%，7 轮交替、restorations 全 0）、净物化中位 25.307ms、通用滚动步 +0.72%（0/7 超带）、RSS −1.86%）；N4（`sameNavigation` 失去共享 buffer 短路）已定量 ≈35µs/次刷新、不物化摘要，本轮不改并登记为微项；**采纳集改为最终 head `21bd9597`：模型层 6 对 16k cold 65.611→30.995ms（−52.90%，6/6 超带 5.29%）、2k −62.07%、materialization 32.480ms、footprint −4.16%、RSS −2.08%，生产门槛 5/5**；前序两批（5958eb23 −52.86%、af42ec4c −52.28%）为独立佐证不合并统计；**第二轮评审 0 BLOCKING / 6 NONBLOCKING 全部处置**（N1 harness 只记录未 guard→措辞限定+v3 加 guard；N2 估计量口径分列（分侧中位比 vs 逐轮配对差中位）并补测至 **7 轮交替**（与 r2 复用同一对 acceptance 二进制）；N3 撤回跨批 base 漂移的布局归因——`af42ec4c` 批与最终批 base 二进制**同为 `d8ce8bab…`** 而中位仍差 1.7%，机制未定→只做统计隔离；~165ms 视图份额与 UI 侧读取差值改标估计；N4 `sameNavigation` 失去共享 buffer 短路→定量 ≈35µs/刷新、不物化摘要，低于 2.5% 门槛故本轮不改，登记队列⑥；N5 撤回「A/B 已覆盖闭包释放」声称（A/B 测正确候选且 model/input 仍存活），M9 记为值等价存活+释放未 pin 的已知缺口；N6 撤回「跳转列表展开同步物化」旧方案并补首次滚动 distinct-buffer 限定）；**CI 15/15（head `1d76eca0`，一次通过）**；**已合并 merge=`efe23dd5`（2026-11-27 21:09）——合并前 mergeable=clean、`origin/main` 无漂移、head 锁定；`git diff c230a333 1d76eca0 -- Sources/ Tests/ scripts/` 为空 ⇒ 产品与测试字节与受审 head `c230a333` 完全一致，按 round-24/41「记录级更正免新复核轮」先例处置，判断与依据写入提交信息**；portable 12/12；PR [#380](https://github.com/chenweigao/perch/pull/380) | [round-2](2026-11-27-round-2.md) |

### round 1 侦察记录（base=1c0d52e0，drift=0）

- 热路径：`Sources/WorkbenchCore/ConversationPresentation.swift:426`
  `Snapshot.presented` → `Presentation.parents(of: rows, into: earlier.foldParents)`；
  `earlier.foldParents` 是 History 缓存 memo 的共享字典，tail 折叠写入触发
  整字典 COW 拷贝（O(earlier)）/每流式 delta。`ConversationPresentation.swift`
  自 84e1d2e9（round-44 base）零改动，round-46 探针结论源级有效。
- round-46 探针（Mac mini，streaming 16k 夹具）：parents 调用 1,706 次、
  平均入参 map 394 项、changes==foldedRows（零空操作写，no-change 快路径无解）。
- 份额警示：停止报告记 `Presentation.parents` 3.65% inclusive（427 样本，
  叶含 `_NativeDictionary.copy()`），`Snapshot.presented` 5.24%——16k 窗口下
  可能贴近噪声带（历史 spread 4–10%）。**先耗时探针定量可转化份额，再决定
  是否扩测量面**（O(窗口)/delta 为算法级缺陷，大窗口下应分离；round-21
  long-tail 测量面扩展先例）。
- 消费点走查（B 授权范围内）：AgentWorkbench `ConversationTranscriptView.swift`
  对 foldParents 仅纯 subscript 查找（:739/:748/:800/:989）与透传存储
  （:368/:395/:430/:466/:536/:881/:884），无迭代无变异→split 类型
  （base+overlay，subscript O(1)）消费侧可滴入。Core 内部 `.keys`（:211）/
  `.merge`（:275/:303）/COW 变异（:305–307）在分页 joined 路径，非流式热路径。
- 设计要点（候选阶段细化）：426 调用点 tail 与 history 的 fold key 结构不相交
  （rows=history.rows+tail，entry id 唯一）→overlay 无需 tombstone；
  `Presentation: Equatable` 与 :211 `.keys` 需语义等价口径（round-27 N1
  教训：规范等价≠字节等价，钉死按有效映射比较）。
- 进展：Mac 工作树已 checkout 1c0d52e0（Swift 6.4，/usr/bin/swift）。
  耗时探针已派发：job `struct-r1-parents-time-20261127`（PerfRunner），
  补丁=.local/struct-round1/parents-time-probe.patch（round-46 计数探针
  + firstWrite/reduce 纳秒计时，git apply --check 通过）；跑 16k（默认
  STREAMING_TURNS=230）与 64k（STREAMING_TURNS=920，既有旋钮，无夹具改动）
  两档；结果在 mini `~/Library/PerfRunner/results/struct-r1-parents-time-20261127.log`
  +`.done`，原始日志在 mini 工作树 `.local/struct-r1/probe-{16k,64k}.log`。
  探针为归因载体（base+probe，非产品候选）；显式循环 vs reduce(into:) 的
  codegen 差异与 DispatchTime.now() 开销（~2×20–40ns/调用）如实披露。
- 16k 探针结果（base=1c0d52e0+probe，Mac mini，job 同名单次运行）：
  calls=1706 mapEntries=672922（avg 394.4，与 round-46 逐值同构）
  foldedRows=61829 changes=61829（零空操作）；reduceNs=27,658,811
  （avg 16.21µs/call）、firstWriteNs=3,706,180（avg 2.17µs/call）。
  同跑 chain_total median 0.39ms、presentation_update 0.14ms、
  older_page_full_chain 1.98ms、commentary_chain_total 0.4523ms。
  **份额裁决（16k）：COW 拷贝本体 2.17µs/390µs≈0.56%，远低于噪声带；
  reduce 全口径 4.2% 与停止报告 3.65% inclusive 吻合，但含探针自身
  changed 计数查找开销（生产不付）与候选仍须付的 36 次插入——可转化
  上限即拷贝本体**。split 假设在 16k 流式场景亚噪声，属 round-13/18/20/21
  "份额≠可转化"家族。64k 档（STREAMING_TURNS=920）运行中，验证 O(窗口)
  缩放是否改变裁决。
- 设计走查（若 64k 翻盘或①依赖时复用）：FoldParents(base+overlay) 语义
  等价（flattened 比较）+ 异构 `== [String:String]` 重载（PresentationHistoryTests
  :174/:382 字面字典比较不改即过）+ isEmpty/keys；History memo 恒 flat
  （joined/joinedIncremental/displayed 三路均 flat）→ :426 split 深度≤2；
  joinedIncremental 用 flattened（overlay 空时 O(1) 返回 base）保持 round-36
  行为；AgentWorkbench 仅 4 处类型标注（:430/:466/:536/:881），subscript 不动。
  PrependIncrementalTests 跨构造路径 Presentation== 要求语义等价（round-27 N1）。
- 战略注记：②本非 10x 候选（few-% 结构清理）；goal 的 10x+ 空间在①（冷首访）
  与⑤（cf-match 调度）。若②缓议，round 2 优先转①盘点，避免在亚噪声候选上
  消耗停止计数。①若立项懒投影，split 表示可能是其前置基础设施（届时以①的
  A/B 承载，不单独立项）。
- 下一步：收 64k 探针 → 终裁②（缓议附原因 / 翻盘则粗筛）→ 更新队列顺序。

### round 2 预备：① Linux 筛选（2026-11-27，base=1c0d52e0，tests-only 尺寸扩展）

冷投影 bench（WORKBENCH_BENCH=1，PresentationBench 尺寸扩至 8k/16k，
补丁=.local/struct-round1/cold-bench-16k.patch，跑后树已还原）：

| slots | messages | cold_median_ms | cold_max_ms | append_median_ms |
| --- | --- | --- | --- | --- |
| 100 | 117 | 2.46 | 4.02 | 0.07 |
| 500 | 583 | 12.13 | 12.79 | 0.10 |
| 1000 | 1167 | 24.21 | 25.36 | 0.10 |
| 2000 | 2333 | 48.43 | 50.31 | 0.17 |
| 8000 | 9333 | 196.37 | 205.78 | 0.50 |
| 16000 | 18667 | **419.51** | 420.17 | 1.05 |

严格线性 O(n)（~22.5µs/条，8× 消息→8.66× 耗时）。**①前提确认**：全窗冷投影
在大会话下数百 ms（Linux 筛选口径；Mac 绝对值待测，按 round-11 Mac@2333
6.73ms 推算 Mac@18.7k 约 120–150ms）。视口受限投影（首访只投影可见尾窗，
余量懒物化）理论余量 20–80x，是本循环的 10x+ 主候选。
产品触发面：缓存未命中的会话切换 / 恢复携带全量历史时 update() 全窗重投影
（presentation cache 保留最近 8 会话）；分页流式路径不受影响。
立项前须钉：Mac 16k 冷基线 + 首访场景在产品中的触发占比（acceptance 探针），
以及正确性面（阅读锚点/查找/导航摘要/折叠/滚动高度）的懒物化契约。

### round 2 ① Mac 冷基线 + 触发面走查（2026-11-27，base=fda922fa + 冷基线补丁）

job `struct-r2-cold-baseline-20261127`（PerfRunner，exit=0，build 64.16s，
跑后 porcelain 空=树已还原）。补丁与 Linux 筛选同一份
（.local/struct-round1/cold-bench-16k.patch，sha256 c85537e0…，派发前
mini 侧 git apply --check 通过且哈希一致）。原始 log=
.local/struct-round1/struct-r2-cold-baseline-20261127.log。base 含 round-1
②采纳；冷路径走 joined（flat），②对流式热路径的收益不计入本基线。
main 其后推进到 0c41b4ef（PR #379，仅 CI workflow + docs，Sources 零改动），
基线对新 main 源级有效。

| slots | messages | cold_median_ms | cold_max_ms | append_median_ms | text_bytes |
| --- | --- | --- | --- | --- | --- |
| 100 | 117 | 0.94 | 7.08 | 0.06 | 43,079 |
| 500 | 583 | 2.90 | 3.40 | 0.05 | 216,839 |
| 1000 | 1167 | 3.67 | 4.25 | 0.04 | 433,229 |
| 2000 | 2333 | 6.83 | 7.53 | 0.07 | 867,923 |
| 8000 | 9333 | 27.64 | 32.09 | 0.22 | 3,473,923 |
| 16000 | 18667 | **63.73** | 64.60 | 0.49 | 6,953,229 |

口径：全新 model 单次 update() 全窗投影，5 次取中位（模型层，不含传输/
布局/FPS）。100 档 cold_max 7.08 为首跑预热伪影，以中位数为准。

- **Mac@16k = 63.73ms**，Linux 筛选 419.51ms 的 1/6.58；单条 3.41µs
  （Linux 22.5µs）。round-11 外推预估 120–150ms **偏保守，如实修正**：
  @2333 实测 6.83ms 与 round-11 的 6.73ms 几乎逐值吻合（+1.5%），偏差来自
  缩放假设——实测轻度超线性（2.93→3.41µs/条，2333→18667；8k→16k 2.30×）。
- ①余量重估：视口受限冷投影（首访只物化可见尾窗）在 16k 理论 20–60×；
  64k 按轻度超线性外推 ~250–280ms（未测，不作证据）。63.73ms 低于 100ms
  感知阈但仍是数帧级停顿，且触发面走查（下）显示大会话**每次重访必冷**。
- **触发面走查（代码级，B 授权范围内只读）**：`WorkbenchModel.swift:13`
  用默认 `ConversationPresentationCache()`；`ConversationPresentation.swift:716`
  默认 capacity=8、**maximumMessages=1_000、maximumPayloadCost=1MiB**，
  :727 retain 守卫超限即弃。16k 夹具 18,667 条 / ~6.95MB 文本，超限 18.7× /
  6.6× → **大会话结构性不入缓存**，"最近 8 会话" LRU 只覆盖小会话；
  大会话每次视图重建（切走再切回 / 恢复 / 重开窗）= 全窗冷重投影。
  视图存活期 handle 保持当前 model（:736 注释）→ 流式 delta 走暖路径，
  不受影响。触发占比的 acceptance 探针（真实使用中视图重建频率）仍待做，
  此为立项门槛余项。
- 竞争方案备忘：抬缓存上限可让大会话重访转暖，但内存代价（8× 大会话
  model，源 + 投影行）未量化；懒投影同时攻冷成本与驻留足迹。裁决留待
  相位归因后，不预决。
- **懒物化正确性契约（草案，候选阶段钉死）**：
  1. 阅读锚点：按 entry id + entry 内偏移锚定，不按行下标；未物化前缀
     用稳定估高，物化修正不得移动已锚定视口（scroll anchoring）。
  2. 查找：全历史查找语义不得缩到已物化子集；契约=查找扫源消息（或
     触发有界全量物化），结果与今日全窗投影逐值一致。
  3. 导航摘要：跳转列表覆盖全部 turn，数量/顺序与 eager 投影相等；
     保留 O(n) eager 或懒建 + 稳定占位，取决于归因中 summary 份额。
  4. 折叠：foldParents 对任意已物化子集正确；②的 split（base+overlay）
     为前置基础设施；折叠态变化不得强制全量物化。
  5. 滚动高度：未物化行估高须单调/稳定到滚动条与锚点恢复可用，
     容差钉进 acceptance 夹具。
- 下一步：(a) **冷相位归因**——update() 已有
  `ConversationPresentationUpdateMetrics` 相位分解（tool/turn/narrative/
  row/summary/retainedCost/compare），cold bench 挂 metricsHandler 打印即可，
  tests-only 补丁、零产品改动，16k 档先出；(b) acceptance 触发占比探针；
  (c) 据 (a)(b) 立候选（懒边界按主导相位定）。

### round 2 ① 冷相位归因（2026-11-27，base=fda922fa + cold-phase-16k.patch）

job `struct-r2-cold-phase-20261127`（PerfRunner，exit=0，build 36.30s，
跑后 porcelain 空）。补丁=.local/struct-round1/cold-phase-16k.patch
（sha256 b49a4f40…，尺寸扩展 + metricsHandler 钉在中位冷跑，same-run；
Linux release 编译筛选过 145.65s）。原始 log=
.local/struct-round1/struct-r2-cold-phase-20261127.log。

| slots | turns rebuilt | cold_median_ms | tools | turns | narrative | rows | retained | total | turns 份额 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 100 | 50 | 1.10 | 0.136 | 0.826 | 0.057 | 0.005 | 0.065 | 1.096 | 75.4% |
| 500 | 250 | 2.78 | 0.322 | 2.262 | 0.002 | 0.000 | 0.176 | 2.762 | 81.9% |
| 1000 | 500 | 3.52 | 0.412 | 2.854 | 0.015 | 0.002 | 0.214 | 3.498 | 81.6% |
| 2000 | 1000 | 6.41 | 0.730 | 5.266 | 0.001 | 0.000 | 0.377 | 6.374 | 82.6% |
| 8000 | 4000 | 26.05 | 3.034 | 21.317 | 0.007 | 0.000 | 1.541 | 25.901 | 82.3% |
| 16000 | 8000 | 62.48 | 6.757 | **51.974** | 0.070 | 0.004 | 3.222 | 62.030 | **83.8%** |

（单位 ms；compare/reset 全尺寸≈0；summary 全 0=bench 默认
summariesEnabled=false，导航摘要在 turns 相位内建，非无成本。）

- **裁决：turns（历史 turn 投影）主导，16k 份额 83.8%**（51.97/62.03），
  份额随尺寸稳定（75–84%）；tools 10.9%、retained 5.2%、narrative+rows
  <0.2%（已尾窗受限）。reused=0/rebuilt=8000 确认全冷。单 turn 成本
  5.3µs@2k–8k → 6.5µs@16k（轻度超线性，与基线同族）。
- 交叉核对：same-run total 62.030 vs cold_median 62.48，差 0.45ms（0.7%）
  =metrics 回调+bracket 口径（回调在 updateEnded 后触发，total 不含、
  bench bracket 含），披露。跨 job：基线 63.73 vs 本次 62.48（-2.0%），
  不同构建（full 64.16s vs incremental 36.30s）——二进制布局变异家族，
  绝对值不跨 job 混合统计；份额为 within-run，不受影响。
- **①懒边界方向（据归因定）**：
  1. 主边界=**按 turn 懒物化**：冷首访只投影可见尾窗 turn， earlier turn
     按需物化（滚动/查找/导航跳转）。理论尾窗成本 ~0.1–0.5ms。
  2. **仅 turns 懒不够 10x**：tools 6.76ms + retained 3.22ms ≈ 10ms 地板
     → ~6×。10x+ 场景须配套：tools 全窗 O(n) 扫描→懒/增量/按需
     （影响历史 tool 解析，需设计评审）；retained messageCosts 全窗 O(n)
     值比较→大会话既结构性不入缓存，成本会计可延迟/上界化（cheap bound
     替代精确 cost， retain 守卫语义不变）。
  3. narrative/rows 已尾窗受限，无需动；导航摘要在 turns 内→懒边界须
     覆盖（契约项 3）；②split 为 foldParents 子集基础设施（契约项 4）。
- 立项门槛余项：~~acceptance 触发占比探针~~（已以 cache-trigger 机制探针替代，见下节）；
  契约草案→候选阶段钉死。
- 下一步：立①候选（分片：turns 懒物化先行，tools/retained 配套
  同 PR 或分轮，按 A/B 证据定）。

### round 2 ① 触发面机制探针（cache-trigger，2026-11-27，base=fda922fa）

补丁=.local/struct-round1/cache-trigger-probe.patch（sha256 e21c8f97…，
tests-only：新增 WORKBENCH_BENCH=cache-trigger，零产品改动；Linux release
编译过）。job `struct-r2-cache-trigger-20261127`（Mac，exit=0，build 37.28s，
跑后 porcelain 空；派发前远端 apply --check 通过，教训 #7 已践行）。
原始 log=.local/struct-round1/struct-r2-cache-trigger-20261127.log。

设计：产品默认 `ConversationPresentationCache()`（8/1000/1MiB）+ 7 小会话
（200 slots）+ 1 大会话（16k slots/18667 条）；80 次切换循环 8 会话（仿
acceptance switching 节奏），每次开新 `ConversationPresentationHandle()`
（=视图重建，产品真实入口）。以 restorationCount 增量判 warm-restore vs
cold-fresh。合成夹具，无真实会话数据。

| 口径 | Linux（筛选） | Mac（产品代表） |
| --- | --- | --- |
| big 重访冷占比 | 10/10 = **100%** | 10/10 = **100%** |
| cache 留存 model | 7（仅小） | 7（仅小） |
| warm restores | 63 | 63 |
| big 冷均耗时 | 439.32ms | **70.00ms** |
| 冷成本/切换总墙钟 | 4430.79/4432.87 ≈ **100%** | 707.46/707.71 ≈ **100%** |

- **运行时证实结构走查**：大会话每次重访必冷（100%），缓存仅留 7 小会话；
  warm restore 走 input-equal 快路径≈0ms，故切换墙钟几乎全部是冷重投影。
  Mac big 冷均 70.00ms vs 基线 63.73ms（+9.9%）=handle 路径+跨 job 二进制
  布局变异家族，披露；份额/机制为 within-run，不受影响。
- **门槛精化（诚实口径）**：原"acceptance 触发占比"要求真实使用中视图
  重建频率——受 no-user-data 红线限制**不可测**。可达成替代=结构走查
  +运行时机制证明（Linux+Mac 100%）+代表模式成本定量（Mac 70ms/重访，
  ~100% 切换成本）。真实频率列为**假设**（代表模式：8 会话循环含 1 大），
  不作证据。据此触发面门槛视为满足（替代口径），立项余契约钉死。
- 节奏教训：设计+机制证明类工作回合内直接做（Linux 可跑模型层探针），
  仅产品绝对值需 mini；短 job 回合内有界收数，不空排唤醒。
