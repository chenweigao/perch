# 20x 性能循环：轮次索引

机制：**用户要求持续接续，不等每日早晨（2026-11-12）**。当前轮结束后在本线程
排下一轮 continuation，收到 CI 事件时优先收尾自己的 PR；避免重叠候选/测量。
历史兜底：会话级 cron 09:47，id 01M77H8AMMB2CVJ3C2ZT65Y30M（当前 Pi 不再确认其存活）。
T3 schedule_task 在当前工具 schema 上创建失败（scheduledTaskId 被错误设为必填），
不能宣称已切换到 interval 调度，也不要每轮重复空参重试。每轮：读本索引与基线 → 同步 origin/main（落后则 rebase；基线相关代码变动则先
复测，漂移 >5% 当轮不做 A/B 结论）→ 选场景 → 单一假设最小修改 → 基线/候选二进制交替
A/B ≥5 轮取中位数 → 超噪声带（本机 <2%）才采纳 → WorkbenchChecks + portable 全绿 +
行为等价有检查钉死 → 轮次报告 + 更新本索引 → conventional commit。

**零介入合并授权（用户 2026-11-12）**：每轮开独立分支 `perf/20x-loop-<N>-<日期>` + PR
（标题带 [perf-loop round N]）；CI 全绿 + 评审意见已处理 + mergeable 确认后
`gh pr merge --merge --delete-branch` 自动合并并在此记录。任何门槛不满足→不合并，留 PR
注明原因。禁止 merge 他人 PR、动主检出、碰用户真实数据/远端连接。

分支纪律：工作在本线程 T3 worktree，各轮本地用 `codex/20x-loop-N-<日期>`，
推独立 `perf/20x-loop-N-<日期>` PR 分支（round 8 起日期为 20261113）。底座：#320
（Linux 可移植性）、#323（round 1）、#324（round 3）、#325（round 5）、#326（round 6）
、#327（round 7）及 #328（round 8）均已合并，当前 base=e160eec。

**macOS 测量通道**：`ssh -o BatchMode=yes mac-mini` 直达（反向隧道，launchd KeepAlive
自愈）。GUI 应用类作业必须走 runner：写 bash 文件到 `~/Library/PerfRunner/jobs/<名>.job`，
LaunchAgent `local.perf.runner`（Aqua 会话内）自动执行，结果在
`~/Library/PerfRunner/results/<名>.log`+`.done`。round 5 起 Mac A/B 使用两个相同默认
SwiftPM builder 的独立 scratch 产品路径，逐对及最终验证二进制hash恒定；归档copied
native checks曾exit137，不能当成功测量，不用带调试权限的xctrace跑数替代无捕获A/B。
SSH 直接拉 GUI 应用会被 TCC 拒绝
（Operation not permitted）。Mac 工作树：`~/_worktrees/20x-loop-20261112/perch`，用前
fetch+checkout 到本轮 base。冷启动经 runner 验证可用（5/5，2026-11-12）。

测量环境：Alibaba Cloud Linux 3（glibc 2.32）x86_64 192 核云机，Swift 6.3.3 AL2，
`PATH=$HOME/.local/swift/6.3.3/usr/bin`。基线见
[../2026-11-12-linux-loop-baseline/REPORT.md](../2026-11-12-linux-loop-baseline/REPORT.md)。
绝对值与 macOS 不可互比；A/B 只用同机同工具链。

红线：不碰 Sources/AgentWorkbench（外观零变化）；行为断言变化 = 回滚；
性能结论必须附交替 A/B 中位数与噪声带。Linux 用于筛选；产品性能候选必须在
Mac mini 同机 A/B 超过该轮实测噪声才采纳，不能把 Linux 特有开销的降低算成产品收益。

## 轮次记录

| 轮 | 日期 | 场景 | 结论 | 报告 |
| --- | --- | --- | --- | --- |
| 1 | 2026-11-12 | 冷投影空白规范化（excerpt 热点） | **已合并：Linux 冷投影 -36.7%**（84.7→53.6ms@2333 条），余场景噪声内；Codex P2 修复后 -36.5% 保持。未据此认证 macOS 倍率 | [round-1](2026-11-12-round-1.md)；#323 已合并（3b679fb） |
| 2 | 2026-11-12 | timeline 文本判空免复制 | **不采纳**：Linux -49.3%，Mac cold +0.8%（噪声内），目标产品无实证收益；已撤回 | [round-2](2026-11-12-round-2.md) |
| 3 | 2026-11-12 | 单 text part 摘要省去重复 Character 计数 | **已采纳/合并：Mac cold -16.75%**（9.85→8.20ms@2333）；等价/Core/portable/app build/5次冷启动、全部8项CI通过，独立及GitHub评审无意见 | [round-3](2026-11-12-round-3.md)；[#324](https://github.com/chenweigao/perch/pull/324)，merge=c51ef15（18:17） |
| 4 | 2026-11-12 | Mac 切换/目录隔离 + CPU 归因 | **归因完成，无产品候选**：9个隔离进程通过，模型投影非切换大头；保持UI红线 | [round-4](2026-11-12-round-4.md) |
| 5 | 2026-11-12 | 编辑统计 contiguous UTF-8 扫描 | **已采纳/合并：Mac -51.23%（2.05x）**，7.987→3.895ms@6400；Character oracle/Core/portable/app build/5次冷启动及全部8项CI通过，两项评审无发现 | [round-5](2026-11-12-round-5.md)；[#325](https://github.com/chenweigao/perch/pull/325)，merge=0711150（19:01） |
| 6 | 2026-11-12 | 未知/只读tool先分类、免路径检查 | **已采纳/合并：Mac stats -13.60%**，3.729→3.222ms@6400；保留首次math CI失败，修复依赖补丁一致性后新head全部8项CI绿，独立评审/最终Codex回执无问题 | [round-6](2026-11-12-round-6.md)；[#326](https://github.com/chenweigao/perch/pull/326)，merge=74dee39（20:27）；[CI修复证据](round-6/ci/README.md) |
| 7 | 2026-11-12 | 无共同首尾/单行编辑免分行数组 | **修订候选：Mac stats -22.39%**，3.220→2.499ms@6400；保留全lazy否定与旧小输入偏慢证据，≤1024bytes走旧算法，50代表场景/完整原样本/各门槛通过，待新head评审CI | [round-7](2026-11-12-round-7.md)；[#327](https://github.com/chenweigao/perch/pull/327)；[短输入复核](round-7/short-input/README.md) |
| 8 | 2026-11-13 | 复用窗口按副本字节比较（delta/翻页/查找缓存） | **已采纳/合并：Mac 每 delta 模型链 -47.60%**（1.145→0.600ms@16,142），tool_projection -91.60%、查找栏 -46.24%、翻页整链 -11.41%；CI 8/8 绿、GitHub Codex 评审同 head 无发现、mergeable CLEAN 后自动合并；Linux edit-lines fullLineDiff +23～31% 已证明是布局伪影（热点指令逐条相同、对照构建同向、Mac 无此退化）；自排独立评审三次被 Claude 限流打断，已明示 | [round-8](2026-11-13-round-8.md)；[#328](https://github.com/chenweigao/perch/pull/328)，merge=e160eec（18:37） |
| 9 | 2026-11-13 | 长单轮状态栏派生免中间数组 | **候选：Mac 单轮 activity -26.38%**（1.6545→1.2180ms@2,000 条）、-25.33%@400 条，六对区间分离；多轮窗口/cold/edit-lines/流式链均无超 spread 变化；新增工具顺序断言在产品代码未改的匹配基线上同样通过；待 CI/评审 | [round-9](2026-11-13-round-9.md) |

## 否定清单（勿重复尝试）

- timeline 的 `trim(...).isEmpty` 改成标量早停：Linux Foundation 大幅受益，Mac
  无超噪声改善。勿重复当 macOS 热点尝试（round 2）。
- 完整lazy行cursor + whole-string canonical equality：单进程Linux筛选使common编辑
  +48–61%、NFC/NFD +165%，已撤回（round7）。最终窄化guard不等于该原型。
- Linux edit-lines 的 fullLineDiff 场景对**代码布局**敏感：round 8 候选里这些场景
  +23～31%，而 `lineDiff`/`fullLineDiff` 的指令在四个二进制里逐条相同、整进程指令数
  -0.017%、IPC 4.322→4.276，两个无产品改动的对照构建同批场景是 -0.4%/-1.2%，Mac 上
  只有 +0.2～0.3%。不要把 Linux edit-lines 的小幅变化当算法结论（round 8）。
- `page_retained_cost` 在同机对照构建之间摆动过 -19.7%…+25.3%，不要单凭它判退化（round 8）。

## 候选队列（按当前证据排序）

1. **round9之后重排热点**：长单轮状态栏派生还剩 1.218ms@2,000 条（Mac），perf children
   里 `ToolVisibilityProjection.project` 3.67% 是最大块——它为状态栏重建整轮 normalized
   消息与 content 数组，而 `ConversationActivity` 只按顺序取工具；考虑给投影加一个
   "只要工具顺序"的出口，但不得改其他调用方的语义。每 delta 链 0.600ms 里
   `displayMessages` 两次调用共 0.18ms（`messages + [live]` 每 delta 复制整个窗口，
   受 API 形状约束，改动会波及 UI，红线内先不动）、narrative 0.16ms。翻页路径
   model_total 3.375ms 里 turn_projection 1.15ms、tool_projection 0.91ms、
   retained_cost 0.77ms，另有 presented_rows 0.79ms。`TurnStatus.swift:89` 仍有
   `Array(messages.dropFirst(start))` 复制；`ConversationActivity.outputCharacters`
   对每个 text/thinking 走 `utf16.count`（可参照 `KimiInFlight` 的既有缓存口径，
   但不得引入全局 memo）。先复剖再立项。
2. **冷投影剩余机制成本**：perf 平坦剖面中 UTF16View 迭代/下标 ~7.7%、
   `IndexingIterator.next` 5.1%、`getEnumCaseMultiPayload` 4.8%——round-1 后
   重跑 perf 定位下一批热点（大概率在行构造或 timeline 分组）。
3. **activity edit_stats 线性成本**：rounds 5–7 后 Mac 6,400 条已降到 ~2.51ms，仍随消息数
   线性；检查是否可增量/懒计算（已有部分增量逻辑，见 2026-10-24 报告）。round 9 已把
   单轮状态栏派生的机械拷贝去掉（-26%），edit_stats 本身未动。
4. **streaming 每 delta 的 tool_projection**：round 8 已把 O(prefix) 的窗口校验
   改为按副本字节比较，Mac 0.595→0.050ms、Linux 1.57→0.07ms；剩余部分是尾轮投影，
   不再是 chain 大头。
5. **Mac mini dashboard 归因（低优先）**：`--mode all`/`dashboard` 在 Mac mini 上
   确定性失败（Missing directory scroll view，mounted=False 但 projection_matches=
   True）；SSH 与 GUI runner 两种上下文同样失败，GitHub CI 同代码通过——本机环境
   因素（候选假设：acceptance app 的偏好域残留、macOS 27.0.1 行为差异、显示器
   状态）。不阻塞轮次；归因前先跑一次全新偏好域 + --mode dashboard 单独复现。
6. **macOS 侧（等用户输入，可选加速项）**：真机切换会话 1.3–1.6s 卡顿归因需要
   用户日常使用中的诊断导出（perch-diagnostics.json）。合成 switching 基线已测：
   median 79–89ms，在产品目标内，无 20x 余量；冷启动 5/5 通过（时长指标待提取）。
   frames/hitch 校准为 2026-09-23 起已知未通过项。
