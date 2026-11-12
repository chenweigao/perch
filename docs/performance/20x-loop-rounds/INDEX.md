# 20x 性能循环：轮次索引

机制：每日自动轮（cron 09:47，会话级；T3 schedule_task 在 acpRegistry harness 上不可用
——`parent_not_active`，勿再尝试除非 harness 变化）。每轮：读基线与本索引 → 选场景 →
单一假设最小修改 → 基线/候选交替 A/B ≥3 轮取中位数 → 超噪声带（本机 <2%）才采纳 →
WorkbenchChecks + portable 全绿 → 轮次报告 + 更新本索引 → conventional commit 推送。

分支纪律：工作在 T3 worktree 分支 `t3/b3eb4bba`（与远端 `perf/20x-loop-20261112` 同步：
`git push origin HEAD:refs/heads/perf/20x-loop-20261112`），底座为已合并的 #320
（Linux 可移植性）。base 更新到新的 origin/main 时必须先复测基线再 A/B。

测量环境：Alibaba Cloud Linux 3（glibc 2.32）x86_64 192 核云机，Swift 6.3.3 AL2，
`PATH=$HOME/.local/swift/6.3.3/usr/bin`。基线见
[../2026-11-12-linux-loop-baseline/REPORT.md](../2026-11-12-linux-loop-baseline/REPORT.md)。
绝对值与 macOS 不可互比；A/B 只用同机同工具链。

红线：不碰 Sources/AgentWorkbench（外观零变化）；行为断言变化 = 回滚；
性能结论必须附交替 A/B 中位数与噪声带。

## 轮次记录

| 轮 | 日期 | 场景 | 结论 | 报告 |
| --- | --- | --- | --- | --- |
| 1 | 2026-11-12 | 冷投影空白规范化（excerpt 热点） | **采纳：冷投影 -36.7%**（84.7→53.6ms@2333 条），余场景噪声内 | [round-1](2026-11-12-round-1.md) |

## 否定清单（勿重复尝试）

（暂无）

## 候选队列（按当前证据排序）

1. **excerpt 的 grapheme 计数残留**：`ConversationTurnSummary.make` 里
   `value.count`/`prefix(320 - value.count)` 仍是 Character 级 O(n) 走查，
   每 part 两次；round-1 后占比上升，可用 UTF16 计数 + 一次性截断等价替换。
2. **冷投影剩余机制成本**：perf 平坦剖面中 UTF16View 迭代/下标 ~7.7%、
   `IndexingIterator.next` 5.1%、`getEnumCaseMultiPayload` 4.8%——round-1 后
   重跑 perf 定位下一批热点（大概率在行构造或 timeline 分组）。
3. **activity edit_stats 线性成本**：6400 条 9.2–9.4ms，随消息数线性；
   检查是否可增量/懒计算（已有部分增量逻辑，见 2026-10-24 报告）。
4. **streaming 每 delta 的 tool_projection 1.58ms**：chain 大头；
   10-24 已有分轮块复用，剩余部分需要 perf 归因后再立项。
5. **macOS 侧（等用户输入）**：真机切换会话 1.3–1.6s 卡顿归因需要用户诊断导出
   （perch-diagnostics.json）；GUI 会话测量（dashboard/frames/冷启动）需要在
   Mac mini 登录会话内执行。合成 switching 基线已测：median 79–89ms，在产品
   目标内，无 20x 余量。
