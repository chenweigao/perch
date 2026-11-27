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

## 候选队列

| # | 候选 | 状态 | 依据 |
| --- | --- | --- | --- |
| ① | 大会话冷首访懒/视口投影 | 盘点+契约+**nav-split 裁决完成**；候选实现中（全 per-turn 懒物化 + tools/retained 配套） | Mac 63.73ms@16k；turns 83.8%；大会话每次重访 100% 冷（Linux+Mac 运行时证实），占切换成本 ~100%；**nav-split：Mac summary 54.6%/timeline 23%/rows 2%，Linux timeline 57.8%/summary 32.7%（主导跨平台翻转，全懒边界平台无关）**；契约 5 项钉死（查找扫源消息天然独立；几何纯值类型为估高接缝；跳转列表展开同步物化） |
| ② | foldParents 整字典 COW 消除（split 表示，API 形态） | **已合并 60420b1a（2026-11-27）** | v2 探针翻盘：拷贝 44.4µs@16k / 308.7µs@64k，chain 份额 11.4%/17.4%；B 授权解锁；正式 16k chain -12.1%/presented -63.3%（6 对）；64k 三对缩放佐证 chain -28.9%/presented -83.9% + v2 独立重建佐证 3 对全负超带 median -30.4% |
| ③ | displayMessages / Array.+ API 形态决策 | 待立项（round-1 附带代码走查） | round-38/42 遗留；Array.+ 8.58% inclusive；64k chain 残余嫌疑=`Snapshot.rows` getter :399 `history.rows+tail` 与 presented :453 `earlier.rows+rows` 每 delta 两次 O(窗口) 拼接（displayed() 空 activity 已有快路径）；②采纳后 64k chain 残余实测 1.09–1.20ms（formal cand，median 1.13）待归因探针定量 |
| ④ | 验证族路径插桩（sameWindow 10.38% / canReuse 5.03% / input-compare 7.49%，重叠） | 待立项（先插桩出净收益下界） | 停止报告重启条件③ |
| ⑤ | 冷首搜 cf-match 调度层（语义不动，改时机/范围） | 待立项（需设计评审） | round-31 归因 cf-match 79%，检测器输出语义红线 |

## 轮次记录

| 轮 | 日期 | 场景 | 结论 | 报告 |
| --- | --- | --- | --- | --- |
| 1 | 2026-11-27 | ② foldParents COW：探针翻盘 + split 候选 | 候选 e40b7054；Linux 113 PASS+1 SKIP、portable、变异电池 4/4；粗筛 v2 通过；**16k 正式 PASS**（6 对 chain -12.1%/presented -63.3%，全负、中位数超带）；64k 三对缩放佐证（chain -28.9%/presented -83.9%，全对超带）+ v2 独立重建佐证 3 对（median -30.4%，全负超带）；**采纳**；评审两轮闭环（0 BLOCKING）；生产门槛 v5 5/5、fixture 门槛 v4 5/5 独立登记；PR [#378](https://github.com/chenweigao/perch/pull/378) **已合并 60420b1a**（复核 0 BLOCKING，CI 15/15，分支已删） | [round-1](2026-11-27-round-1.md) |
| 2 | 2026-11-27 | ① 冷首访懒物化：盘点+契约+nav-split | 基线 63.73ms@16k、turns 83.8%、触发 100% 冷（三节见下）；契约钉死版立（5 项走查坐标+架构接缝）；**nav-split 翻盘：summary 主导 Mac 冷路径 54.6%（Linux timeline 主导 57.8%），rows 可略→全 per-turn 懒物化**；修订架构=壳+按需 timeline/rows/summary + tools/retained 配套（理论 30–60×）；分支 perf/struct-2-20261127；候选实现中 | [round-2](2026-11-27-round-2.md) |

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
