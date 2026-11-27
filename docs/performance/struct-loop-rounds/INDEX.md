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
Mac 工作树 `~/_worktrees/20x-loop-20261112/perch`（当前停在 0e2758ec，
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
6. **SSH 下 `open -n` 不可作冷启动存活门槛**（round-1 门槛 v2 5/5 假失败）：
   LaunchServices 冷注册可在 12s 窗口内不拉起进程且 open 返回 0；直接 exec
   app 二进制 + `$!` 精确 PID 确定性存活（隔离仍靠拷贝+独立 bundle ID+重签）。

## 候选队列

| # | 候选 | 状态 | 依据 |
| --- | --- | --- | --- |
| ① | 大会话冷首访懒/视口投影 | 待立项（Linux 筛选已确认前提；Mac 基线待测） | 20x 基线报告：16k 外推 ~580ms 模型层；100x 拉伸场景 |
| ② | foldParents 整字典 COW 消除（split 表示，API 形态） | **round 1 正式 PASS 两档，采纳（门槛/评审/CI 进行中）** | v2 探针翻盘：拷贝 44.4µs@16k / 308.7µs@64k，chain 份额 11.4%/17.4%；B 授权解锁；正式 16k chain -12.1%/64k -28.9%，presented -63.3%/-83.9% |
| ③ | displayMessages / Array.+ API 形态决策 | 待立项（round-1 附带代码走查） | round-38/42 遗留；Array.+ 8.58% inclusive；64k chain 残余嫌疑=`Snapshot.rows` getter :399 `history.rows+tail` 与 presented :453 `earlier.rows+rows` 每 delta 两次 O(窗口) 拼接（displayed() 空 activity 已有快路径）；②采纳后 64k chain 残余实测 1.09–1.20ms（formal cand，median 1.13）待归因探针定量 |
| ④ | 验证族路径插桩（sameWindow 10.38% / canReuse 5.03% / input-compare 7.49%，重叠） | 待立项（先插桩出净收益下界） | 停止报告重启条件③ |
| ⑤ | 冷首搜 cf-match 调度层（语义不动，改时机/范围） | 待立项（需设计评审） | round-31 归因 cf-match 79%，检测器输出语义红线 |

## 轮次记录

| 轮 | 日期 | 场景 | 结论 | 报告 |
| --- | --- | --- | --- | --- |
| 1 | 2026-11-27 | ② foldParents COW：探针翻盘 + split 候选 | 候选 e40b7054；Linux 113 PASS+1 SKIP、portable、变异电池 4/4；粗筛 v2 通过；**正式 PASS 两档**（16k chain -12.1%/presented -63.3%，6/6 全负、中位数超带；64k chain -28.9%/presented -83.9%，全对超带）；**采纳**，产品门槛/评审/CI 进行中；PR [#378](https://github.com/chenweigao/perch/pull/378) | [round-1](2026-11-27-round-1.md) |

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
