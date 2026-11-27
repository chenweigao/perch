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

## 候选队列

| # | 候选 | 状态 | 依据 |
| --- | --- | --- | --- |
| ① | 大会话冷首访懒/视口投影 | 待立项（先测 Mac 真机首访占比与 16k 基线） | 20x 基线报告：16k 外推 ~580ms 模型层；100x 拉伸场景 |
| ② | foldParents 整字典 COW 消除（split 表示，API 形态） | **round 1 进行中** | round-46 探针定量；B 授权解锁 |
| ③ | displayMessages / Array.+ API 形态决策 | 待立项 | round-38/42 遗留；Array.+ 8.58% inclusive |
| ④ | 验证族路径插桩（sameWindow 10.38% / canReuse 5.03% / input-compare 7.49%，重叠） | 待立项（先插桩出净收益下界） | 停止报告重启条件③ |
| ⑤ | 冷首搜 cf-match 调度层（语义不动，改时机/范围） | 待立项（需设计评审） | round-31 归因 cf-match 79%，检测器输出语义红线 |

## 轮次记录

| 轮 | 日期 | 场景 | 结论 | 报告 |
| --- | --- | --- | --- | --- |
| 1 | 2026-11-27 | ② foldParents COW：侦察 + 耗时探针 + 候选 | 进行中 | 本行 |

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
- 下一步：收探针结果 → 算可转化份额（avgReduceNs/chain_total；firstWriteNs
  随窗口缩放验证 O(窗口) 机制）→ 份额成立则 split 候选（base+overlay，
  426 调用点 key 不相交→无 tombstone；Equatable 按有效映射）粗筛 → 正式
  六对 → 评审 → 合并或记录否决；16k 亚噪声则以 64k 缩放场景为采纳面
  （round-21 测量面扩展先例）或缓议。
