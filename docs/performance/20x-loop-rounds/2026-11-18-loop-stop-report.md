# 20x 性能循环停止报告（2026-11-18，停止规则②）

## 触发条件

**停止规则②（基础设施阻塞）**：独立评审通道不可用。

`delegate_task` 对 target `{providerInstanceId:"acpRegistry_kimi_code",
model:"aone/gpt-6.1-sol"}` 连续 **3 个 goal 轮次、5 次尝试**返回同一错误：

```
{"_tag":"OrchestratorMcpFailure","code":"parent_not_active",
 "message":"The calling provider no longer owns an active thread run."}
```

两次来自 T3 工具层，三次来自 ACP CLI 桥
（`ELECTRON_RUN_AS_NODE=1 $T3_ACP_MCP_NODE acp-mcp-call delegate_task`）；**两条通道
同一错误**，说明是 orchestrator 对父线程 run 的拒绝，不是工具层 schema/参数问题。
同一桥的 `orchestrator_capabilities` 调用**正常返回**，且 `aone/gpt-6.1-sol` 确实存在
于 `acpRegistry_kimi_code` 下——模型与通道都在，只有 delegate 创建被拒。

原始证据：`.local/round44/review-channel-failure.log`（含时间戳与每次尝试的完整错误）。

## 停止时的循环状态

| 项 | 状态 |
| --- | --- |
| 已完成轮次 | round 11 – 43（33 轮，全部合并） |
| 当前轮 | round 44（评估轮，零产品改动） |
| PR | [#366](https://github.com/chenweigao/perch/pull/366)，head `3890d81f`（停止记录后追加本报告） |
| 该 PR 门槛 | CI 15/15 SUCCESS（含第 50 例 flake 重跑转绿）；mergeable=MERGEABLE；**独立复核两轮均返回意见、最新一轮已照改待再核** |
| 停止计数 | 2/3（round 43、44 无超噪声可采纳收益） |
| 未合并轮次 | round 44（blocked on 评审门槛） |

round-44 的实质内容（已归档、可独立复核）：

- 叶机械桶消费方归因：四桶（utf16-bridge / arc-copy / cf-match / teardown，显示值之和
  59.66%；原始 union 6974/11691 = 59.65%）分解为 find-bar 线 20.13%、harness 8.50%、
  未解析 1.09%、产品 29.93%；产品侧最大单点 `Array.+` 8.58%（93.52% 来自 displayMessages
  冷拼接，round-43 已按 API 红线裁决），其次 `Presentation.parents` 2.37%。
- 验证族统一净估：**≤2% 上界已撤回**（扫描范围随路径而变，需按路径插桩）。
- 分析器三轮错误（运行时机械帧、修饰前缀漏过、剥离后原始拼写规则失效、剩余复制/扩容机械帧）与两轮评审
  更正全部如实入档。

## 为什么停止而不是继续

循环契约要求每轮以「已合并的 PR」或「记录在案的不采纳结论（报告 + INDEX 行）」结束，
且合并门槛是 **CI 全绿 + 评审意见已处理 + mergeable 三者齐备**。评审通道不可用时：

- 合并 = 违反门槛（不可伪造评审通过）；
- 继续开 round 45 会在 round 44 未合并的情况下叠加未合并轮次，且同样无法通过评审门槛；
- 循环规则明确禁止「硬闯」。

## 恢复方式

评审通道恢复（新的用户触发轮次即可，历史首次评审正是在用户触发的轮次中成功的）后：

1. 对 PR #366 head `865d6f4c` 重新派 `delegate_task`（brief 已备好：F1 机制帧 / F2
   Array.+ 拆分 / F3 扫描范围与 ≤2% 撤回 / F5 汇总与撤回 / 文档一致性）；
2. 处理其发现 → 三门槛齐备 → `gh pr merge --merge --delete-branch`；
3. round-45 候选已用本轮数据收窄：`ToolVisibilityProjection.projectTurns`（6.36%，
   流式链中该函数 inclusive 份额；**栈共现层面**与 `canReuse` 5.03% 从不共现，
   但这不等于「同一次更新不会先后执行两者」——源码显示 `projectTurns` 只在 `canReuse`
   失败后进入）；`sameWindow` 合计 10.38%，其中 5.59% 属 find-bar 红线、4.79% 在
   `TV.update`/`canReuse`。先做源码级范围确认再决定立项或探针。

## 本轮之前的完整战绩（供续接）

round 11–43 共 33 轮，采纳轮次的 Mac 主指标：round 11 −19.16%（cold）、41 −8.26%
（commentary chain）、42 −20.88%（chain_total，循环单轮最大）等；每轮报告与 A/B 证据
在 `docs/performance/20x-loop-rounds/` 下按轮次归档，INDEX 轮次表 round 11–44 行齐备、
报告链接全部可解析（本会话已审计）。