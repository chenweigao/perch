# 20x 性能循环总结报告（2026-11-18，停止规则①）

## 触发条件

**停止规则①（连续三轮无超噪声可采纳收益）**：

| 轮次 | 性质 | 产品收益 | 计数 |
| --- | --- | --- | --- |
| round 43 | 评估 + memo pin 增强（PR #365，merge `9ed2ac1c`） | 无（零产品字节） | 1/3 |
| round 44 | 叶机械桶消费方归因（PR #366，merge `84e1d2e9`） | 无（零产品字节） | 2/3 |
| round 45 | `ToolVisibilityProjection` 冷构建/温复用探针（本 PR） | 无（零产品字节） | **3/3** |

round-45 的判据（详见 [2026-11-18-round-45.md](2026-11-18-round-45.md)）：

- `projectTurns` 6.36% inclusive 中，探针显示 16 次进入恰为 8 次冷缓存全量重建
  （1,864 次重建全部在此）+ 8 次完整缓存全量复用（1,846 次复用、零重建）；
  冷构建是首次投影必经成本，温路径已无整窗重算。
- 温路径残余（`projectTurns` 本体 20.70% + `identities(in:)` 10.22% 的样本份额
  ≈ 全样本 2%）低于分类器噪声带。
- `Snapshot.presented` 5.24% 的主体 `Presentation.parents` 2.37% 自 round-42 起已增量。

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
且连续三轮无超噪声可采纳收益即停止。round 43–45 已连续三轮满足停止条件；继续开
round 46 只会重复同类评估，且每轮的独立评审需要单独的用户触发回合，无法在自动
续跑中完成门槛。

## 剩余轮次（round 46–110）未尝试

按契约「停止规则触发时输出总结报告」，以下方向留档，供后续重启参考：

1. **需要 API 层决策**的候选：`Array.+` 8.58%（displayMessages 冷拼接，返回
   `[KimiMessage]` 的 public API 红线）；`ConversationSearch` 红线内匹配（cf-match）。
2. **需要新测量面**的候选：验证族统一（`sameWindow` 10.38%、`TV.canReuse` 5.03%、
   input-compare 7.49%，重叠），round-44 已撤回定量上界，重启需先按路径插桩。
3. **结构性成本**：`projectTurns` 冷构建、`Presentation.parents` 2.37%——当前证据
   显示无可谈判的温路径冗余。

## 重启条件

满足任一即可重新开启循环（从 round 46 起）：

- 出现新的 >2.5% 可攻产品单点（新归因数据，而非旧 trace 重排）；
- 产品 API/契约变更解除现有红线（例如 displayMessages 返回形态）；
- 验证族按路径插桩完成，给出可复核的净收益下界。

## 证据索引

- 轮次表与全部结论行：`docs/performance/20x-loop-rounds/INDEX.md`
- round 44 归因：`round-44/attr/consumer-attribution.txt`、`consumer-views.txt`、
  `round-44/ATTRIBUTION-NOTE.md`
- round 45 探针：`round-45/probe.patch`、`round-45/probe-counters.txt`
- 上一份停止报告（停止规则②，评审通道 `parent_not_active`，已随用户触发轮次解除）：
  `2026-11-18-loop-stop-report.md`