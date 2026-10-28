# 长会话流式更新的全量投影（2026-10-23）

## 真机报告

用户在浏览一个正在运行的长 Kimi 会话（向上滚动、逐页加载更早消息）时 Perch 接近卡死。
导出的帧诊断（Perch 0.2.1，bundle 672，`v0.1.0-534-gd716933`，macOS 26.6.2，60 Hz）：

- 录制 59.6 s，掉帧 438 次，丢帧 2,133 帧（约 35.5 s，主线程约 60% 时间被占）；
  ≥100 ms 的间隔 142 次，最长 1.63 s。
- `snapshot_projection` 180 次、合计 6.4 s、平均 35.6 ms，单次最高约 126 ms；
  明细为 `messages=14915→16425 rows=594→690`，且伴随 `thinkingPreview` 行：会话在运行，
  已加载窗口每约 3 s 增加 100 条（分页）。
- 未归因 35.5 s。

## 原因

每个流式 delta（`thinking.delta` 等）都改变 `connection.conversation`，使
`KimiWorkspaceView` 与 `ConversationTranscript` 重新求值，并对**整个已加载窗口**重算：

- `ConversationPresentationModel.update`：工具可见性投影重建全部消息、按轮分组比较、
  逐行工具映射、payload 成本；
- 视图层 `displayedRows` + 过程折叠 + `foldParents`；
- 活动栏 `ConversationActivity` 中的 `SessionEditStats.derive`（整段会话、逐条编辑分行；
  未插桩，计入未归因）。

成本与已加载消息数线性相关；运行中的会话每个 delta 都付一次，主线程因此持续饱和。

## 修改

- **历史只投影一次**：以最新一条用户提示为界，之前的轮次（历史）的工具可见性输出、
  时间线行和导航在快照之间共享；delta 只投影最新一轮。任何可能与完整重算不同的情况都
  回退全量：最新一轮的工具 ID 也出现在历史中（如迟到的结果、ID 复用、无 ID 部件的位置 ID）、
  已记住的 live 工具在历史中解决、运行 ID 或连接状态影响历史工具、条目 ID 跨界重复、语言或
  epoch 变化。产生过跨界的前缀不会被复用。
- **`Snapshot.presented`**：历史部分的摘要叠加与折叠按（叠加摘要、是否折叠）缓存；
  折叠按轮决定，在最新提示处可精确拆分。
- **`SessionEditStatsCache`**：编辑统计按文件求和，历史部分缓存，最新一轮累加；由视图持有。
- 输入比较从末尾开始（流式只改最后一条）；`runningIDs` 去掉整窗分配并自尾部扫描。

## 结果

Linux x86_64，Swift 6.0.3 release，`WORKBENCH_BENCH=streaming`：231 轮、16,142 条消息
（4,843 条时间线行，折叠后 703 行，与真机 16k 条 / 690 行同量级），每轮 34 次工具调用，
最后一轮运行中；按视图顺序重放一次思考 delta 的同步模型工作。各 3 轮、每轮 30 次中位数：

| 阶段 | 基线 e0c7787 | 本修改 |
| --- | --- | --- |
| `ConversationActivity`（活动栏） | 13.1–13.2 ms | 1.2 ms |
| `ConversationPresentationModel.update` | 44.4–44.6 ms | 1.9 ms |
| displayed + 折叠 + foldParents / `presented` | 8.1–8.6 ms | 0.06 ms |
| **每个 delta 合计** | **66.7–67.5 ms** | **3.9 ms** |
| 加载一页更早消息（全量） | 63.9–65.1 ms | 67.5–71.6 ms |

分页仍是全量重算（并建立一次历史缓存，约多 6%），属离散的用户操作。释放整个 16k 会话的
模型状态约 12 ms，不能解释真机切换会话后 1.3–1.6 s 的无归因卡顿。

## 验证

- `checkConversationPresentationHistory`：29 步序列（token、运行集合、跨界结果、离线/重连、
  位置 ID、条目 ID 冲突、分页、语言、完成、ID 复用的 live 工具、新提示、epoch、无提示）逐步与
  完整重算比较行、导航、叙事、摘要批次与 payload 成本，并对 4 种摘要叠加 × 折叠 × 运行状态比较
  `presented`；断言预期的复用与拒绝。另检查拆分投影拼接等于完整投影。
- 变异检查：去掉"跨界前缀不复用"、历史折叠误用运行状态、去掉运行集合守卫，三者均被该检查捕获。
- `checkSessionEditStatsCache`；Linux WorkbenchChecks 69 PASS；portable 套件；preview-sources。

## 未验证

- AgentWorkbench 的三处视图改动只能由 macOS CI 编译。
- 真机帧数据：需在 Mac 上用同类长会话重录诊断报告（设置 → 诊断 → 性能诊断）。
  基准不含 SwiftUI/AppKit 布局与 snapshot_apply；未归因时间中这部分的比例未知。
- 切换会话后的长卡顿未定位。

## 复现

```sh
swift build -c release --product WorkbenchChecks
WORKBENCH_BENCH=streaming .build/release/WorkbenchChecks   # STREAMING_TURNS 可改轮数
```
