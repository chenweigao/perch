# 评审通道协议（T3 `parent_not_active` 的处置）

本文档记录 20x 性能循环中反复出现的 T3 orchestrator 故障及其固定处置方式，
避免每轮重新摸索。

## 现象

`delegate_task` / `link_pull_request` / `watch_pull_request` 返回：

```
{"_tag":"OrchestratorMcpFailure","code":"parent_not_active",
 "message":"The calling provider no longer owns an active thread run."}
```

同时段 `orchestrator_capabilities` 正常、模型 `aone/gpt-6.1-sol` 可用、
ACP CLI 桥同样被拒——不是参数或权限问题，是 **orchestrator 只接受“当前仍活跃的
父 run”发起的调用**。

## 触发条件（已取证）

1. **goal 自动续跑回合**：几乎必失败（`.local/round44/review-channel-failure.log`，
   7 次尝试）。
2. **同一用户回合内跑了很久之后**：重活（Mac mini 构建、探针、后台 commit/push）
   之后，该回合的 run 不再活跃，随后的 T3 调用全部失败
   （`.local/round45/review-channel-failure.log`）。
3. **新用户回合开头**：稳定可用（多次验证；本轮 `watch_pull_request` 也正常）。

## 协议

1. **T3 调用前置**：每个需要评审/链接/监视的回合，**第一件事**就是发
   `link_pull_request`、`watch_pull_request`、`delegate_task`，再开始构建/测量。
2. **重活与 T3 分离**：构建、探针、A/B、后台任务放在“不需要再发 T3 调用”的回合，
   或放在 T3 调用之后；一旦本回合已出现 `parent_not_active`，不要重试同一调用，
   直接把剩余工作做完并交回，下一回合补发。
3. **评审独立成回合**：推送 head 后，下一个回合只做“链接 + 派评审 + watch + 结束”，
   让评审完成事件把回合唤醒；不要在派评审前先跑长任务。
4. **失败留证**：每次失败把时间、head、调用名、错误追加到
   `.local/roundN/review-channel-failure.log`；不伪造评审通过，不绕开评审门槛。
5. **长命令用前台 + 显式 timeout**，避免被自动转入后台后回合提前结束；
   必须后台时，先完成 T3 调用。

## 验证记录（2026-11-18 18:10，cron 触发回合）

用一次性定时任务（CronCreate，id `01M7Q1YS9DWB9C09BAZ1CY3M1M`）验证“定时触发的回合
能否创建子代理”：

- ① `t3_thread_configure`（只读）→ 成功返回线程配置；
- ② `delegate_task` → `{"_tag":"OrchestratorMcpFailure","code":"parent_not_active",
  "message":"The calling provider no longer owns an active thread run."}`

结论：**定时任务触发的回合也不算活跃 run**。目前唯一可用的入口仍是用户消息触发的
回合；cron 只能用来做非 T3 的工作（构建、测量、`gh` 操作），不能用来派评审。

## 批量评审模式（用户批准，2026-11-18）

由于评审通道只能在用户回合使用，用户批准改为**批量评审**：

- **轮次照常推进**：每轮仍按契约完成选题、测量、报告、INDEX 行、分支与 PR，
  但**不在同一轮等待评审**；PR 记为「待批量评审」。
- **评审集中处理**：在用户回来的回合里，按 PR 顺序逐个 `delegate_task` 评审，
  处理发现后再合并。
- **合并门槛不放宽**：CI 全绿 + 评审意见已处理 + mergeable 三者齐备才合并；
  批量模式下只是把「评审发生的时点」后移，不跳过评审。
- **栈式 PR**：后续轮次的分支基于前一未合并轮次的 head，避免 INDEX/报告冲突；
  PR 以栈形式链接，按顺序合并。

## 影响

- 每轮评审最多在“用户回合开头”推进一次；因此循环的节奏是
  **一条用户消息 → 一个回合完成链接/派评审 → 评审完成事件唤醒 → 处理并合并**。
- 这不是代码缺陷，repo 侧无法修复；上面的时序协议是唯一可控的缓解手段。