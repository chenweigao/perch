# 20x 性能循环总结报告（2026-11-18，停止规则①）

## 触发条件

**停止规则①（连续三轮无超噪声可采纳收益）**：

| 轮次 | 性质 | 产品收益 | 计数 |
| --- | --- | --- | --- |
| round 43 | 评估 + memo pin 增强（PR #365，merge `9ed2ac1c`） | 无（零产品字节） | 1/3 |
| round 44 | 叶机械桶消费方归因（PR #366，merge `84e1d2e9`） | 无（零产品字节） | 2/3 |
| round 45 | `ToolVisibilityProjection` 冷构建/温复用探针（本 PR） | 无（零产品字节） | **3/3** |

round-45 的判据（详见 [2026-11-18-round-45.md](2026-11-18-round-45.md)）：

- `projectTurns` 6.36% inclusive 中，探针把 16 次进入分成 **8 次冷缓存**
  （1,850 次重建、0 复用）与 **8 次完整缓存**（1,846 次复用、14 次重建，页前置边界）；
  温路径不再整窗重算，但并非零重建。
- 探针只计次数、不计耗时，因此无法给出温路径的耗时分担；本轮裁决是
  **证据不足、不采纳**，不是“已证明低于噪声带”。
- `Snapshot.presented` 5.24%（613 样本）的完整 inclusive 中，`Presentation.parents`
  为 **427 样本 / 3.65%**——round-44 的 2.37% 只是四桶消费方份额；其叶帧含
  `_NativeDictionary.copy()`，**该候选保持开放**，需温路径耗时测量后再判。

## 循环状态

| 项 | 状态 |
| --- | --- |
| 完成轮次 | round 11 – 44（34 轮，全部合并）；round 45 记录随本 PR 合并 |
| 起点 | round 11（断点恢复，见 INDEX） |
| 当前 base | `84e1d2e9`（round-44 merge）；round-45 PR 合并后前进 |
| 停止计数 | **3/3（触发停止规则①）** |
| 未合并轮次 | round 45（本 PR；合并后无未合并轮次） |
| 否定清单 | 见 INDEX「否定清单」小节（所有条目均未重试，符合契约） |

## 循环内已落地的产品收益（round 11–42，全部合并）

- round 30 entry 缓存跨实例验证（find_bar_reopen −88.26%）；
- round 38 narrative tool-step 解析记忆化（chain_total −23.14%）；
- round 41 commentary 增量 derivator（commentary_chain_total −8.26%，循环首次双端主指标分离）；
- round 42 displayMessages box-per-lineage 惰性 memo（chain_total −20.88%，循环单轮最大收益）；
- 其余轮次按 INDEX 逐轮记录（采纳或「不采纳/无候选」结论行）。

round 43–45 的产出是**证据收口**而非收益：memo pin 补强、叶桶闭集归因方法、
验证族 ≤2% 上界撤回、`projectTurns` 冷/温成本分解。

## 为什么停止而不是继续

循环契约规定：每轮必须以「已合并的 PR」或「记录在案的不采纳/无候选结论」结束，
且连续三轮无超噪声可采纳收益即停止。round 43–45 已连续三轮满足停止条件，因此
**停止规则①被触发**——这是契约的机械结果，不是“候选已耗尽”的判断：`parents`/
`Snapshot.presented` 与耗时分担测量仍是未做完的工作（见下节）。

## 剩余轮次（round 46–110）未尝试

按契约「停止规则触发时输出总结报告」，以下方向留档，供后续重启参考：

1. **需要 API 层决策**的候选：`Array.+` 8.58%（displayMessages 冷拼接，返回
   `[KimiMessage]` 的 public API 红线）；`ConversationSearch` 红线内匹配（cf-match）。
2. **需要新测量面**的候选：验证族统一（`sameWindow` 10.38%、`TV.canReuse` 5.03%、
   input-compare 7.49%，重叠），round-44 已撤回定量上界，重启需先按路径插桩。
3. **待补耗时测量**：`Snapshot.presented` 5.24%（含 `Presentation.parents` 3.65%
   inclusive）仍是开放候选；`projectTurns` 冷构建（1,850 次重建）与温路径 14 次
   页边界重建需要耗时探针才能判断可攻性。

## 重启条件

满足任一即可重新开启循环（从 round 46 起）：

- 出现新的 >2.5% 可攻产品单点（新归因数据，而非旧 trace 重排）；
- 产品 API/契约变更解除现有红线（例如 displayMessages 返回形态）；
- 验证族按路径插桩完成，给出可复核的净收益下界。

## 证据索引

- 轮次表与全部结论行：`docs/performance/20x-loop-rounds/INDEX.md`
- round 44 归因：`round-44/attr/consumer-attribution.txt`、`consumer-views.txt`、
  `round-44/ATTRIBUTION-NOTE.md`
- round 45 探针：`round-45/probe.patch`（v2，含冷/温交叉统计与 atexit 最终行）、
  `round-45/probe-counters.txt`
- 上一份停止报告（停止规则②，评审通道 `parent_not_active`，已随用户触发轮次解除）：
  `2026-11-18-loop-stop-report.md`