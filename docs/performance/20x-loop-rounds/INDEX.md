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

**独立评审通道（用户指令 2026-11-13）**：一律用 `delegate_task` target
`{providerInstanceId: "acpRegistry_kimi_code", model: "aone/gpt-6.1-sol"}`，只读共享检出；
不再向 claudeAgent/claude-opus 派评审，也不要等 Claude。评审发现逐项处置后由同一模型
复核（每次复核是新 delegate_task）；评审明示的逐字更正可直接照改并自行重算验证，
不必再起一轮复核。每轮合并后，下一轮分支的**首个提交**按 ae4563f 先例专门定稿上一轮
（INDEX 行 + 报告"合并记录"节），不与工作提交混在一起。

分支纪律：工作在本线程 T3 worktree，各轮本地用 `codex/20x-loop-N-<日期>`，
推独立 `perf/20x-loop-N-<日期>` PR 分支（round 8 起日期为 20261113）。底座：#320
（Linux 可移植性）、#323（round 1）、#324（round 3）、#325（round 5）、#326（round 6）
、#327（round 7）、#328（round 8）、#329（round 9）、#330（round 10）、#333
（round 11）、#334（round 12）、#335（round 13 不采纳记录）及 #336（round 14）均已合并；main 另有 #331（CI 并行化，非循环产物，测量子树逐字节不变），
当前 base=1bcbc00（round-23 合并）。

**macOS 测量通道**：`ssh -o BatchMode=yes mac-mini` 直达（反向隧道，launchd KeepAlive
自愈）。GUI 应用类作业必须走 runner：写 bash 文件到 `~/Library/PerfRunner/jobs/<名>.job`，
LaunchAgent `local.perf.runner`（Aqua 会话内）自动执行，结果在
`~/Library/PerfRunner/results/<名>.log`+`.done`。round 5 起 Mac A/B 使用两个相同默认
SwiftPM builder 的独立 scratch 产品路径，逐对及最终验证二进制hash恒定；归档copied
native checks曾exit137，不能当成功测量，不用带调试权限的xctrace跑数替代无捕获A/B。
裸 `swiftc` 独立二进制在 mini 上被系统 SIGKILL（hello-world 可复现，/tmp 与 $HOME 均
exit 137；SwiftPM 构建正常）：临时 Mac 测量一律用 SwiftPM scratch 包，解释器模式
（`swift file.swift`）微基准对这类代码无效（stdlib 原生 vs 解释闭包偏斜，round 12 diag）。
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
| 9 | 2026-11-13 | 长单轮状态栏派生免中间数组 | **已采纳/合并：Mac 单轮 activity -26.38%**（1.6545→1.2180ms@2,000 条）、-25.33%@400 条，六对区间分离；CI math 门槛在 3 CPU 共享 runner 上三次失败（每次卡的门槛与构建出的二进制 hash 都不同），Mac mini 静机同脚本/同 6 轮顺序/同门槛全绿（parse 0.97–1.00、typeset best 1.13/1.01/0.99），据此判为 runner 噪声，未改任何门槛或断言；证据随 docs 提交换新 head 后 8/8 全绿合并；自排独立评审五次被 Claude 限流未跑成，已明示 | [round-9](2026-11-13-round-9.md)；[#329](https://github.com/chenweigao/perch/pull/329)，merge=a9bca95（20:32）；[CI 取证](round-9/ci/math-gate-investigation.json) |
| 10 | 2026-11-13 | 定时信封裁剪前的 O(1) 守卫 | **不采纳**：Linux 冷投影 -17.89%（51.595→42.365ms@2,333），Mac -0.96%（8.32→8.24ms，区间重叠、噪声内），是 corelibs `trimmingCharacters` 走 UTF-16 的 Linux 特有开销；候选构建 Mac edit64_bulk +15.04% 超其 13.88% spread，为回归信号、随撤回不保留；产品补丁已撤回，保留 8 条钉住既有空白/近似输入边界的断言（两端产品代码未改的匹配构建通过，Mac 验证构建 8b294a15）与两端六对数据；gpt-6.1-sol 独立评审三轮（初审+两次复核）共 8 项 BLOCKING + 2 项非阻塞发现的逐项处置见报告"独立评审与修正记录"；首个 head 的 navigation-disclosure 超时未在其后三个 head 复现，判 runner 抖动 | [round-10](2026-11-13-round-10.md)；[#330](https://github.com/chenweigao/perch/pull/330)，merge=d1590e4（22:17）；[撤回补丁](round-10/rejected-cron-guard.patch)；[Mac 提交配置验证](round-10/macos-committed-checks.json) |
| 11 | 2026-11-14 | collapsedWhitespace 零拷贝字节路径 + 永不绑定预过滤 | **已采纳/合并：Mac 冷投影 -19.16%**（8.325→6.730ms@2,333，spread 4.75%，六对全分离），四尺寸 -17～-19%；xctrace 归因 collapsedWhitespace 30%+prefix 字素行走 20.8%+trim 仅 0.9%；穷举走查暴露 Prepend 集既有缺口（U+111C3/U+113D1）按契约先修，7 标量特征化缺口钉住未修；两次独立 run 二进制逐字节复现；display_messages_workspace +10µs（一格量化、区间重叠）已披露；Linux 筛选 -6.3% 同向；gpt-6.1-sol 评审 CLEAN（3 处非阻塞措辞已修复）、CI 13/13 绿 | [round-11](2026-11-14-round-11.md)；[#333](https://github.com/chenweigao/perch/pull/333)，merge=7d5ba26（03:01）；[归因](round-11/macos-xctrace-attribution.json) |
| 12 | 2026-11-14 | find-bar 未变条目 hits 整体复用（开查找栏 streaming） | **已采纳/合并（v5=13933f8）：Mac find_bar_query_update -45.10%**（0.510→0.280ms@16,142 条，spread 6.12%，六对全分离 -220～-240µs），Linux 筛选 -33.33% 同向分离；复剖：search 区域占 streaming 全样本 52.6%（locale 匹配 langid+DD lexer+fold ~13.4% + UTF16 索引转换 5.1%）、SessionEditStats 占 activity 测量段 57.3%（队列首位）；条目 hits 为 (messages,isRunning,query,options) 纯函数，编码精确查询键 + sameSearchableWindow（字节层 ∨ 值层∧渲染字节层：数值 bitPattern、字符串/对象键 UTF-8 字节、JSONValue/KimiPart 结构级位比较短路、排序键对齐 O(k log k)）+ sources 字节比较三重校验后整体复用并收养新副本；钉死拆分矩阵/探针：矩阵（单字段差异+同查询夹逼+running 翻转三恒定夹逼）在未优化产品全过，五探针一次运行记录四个既有洞（prefix 零号符号、NFD 查询键往返、payload/对象键 NFC→NFD——round-8 起 Earlier/Tier-2 规范比较漏洞；字面量探针基线通过仅钉候选）；评审处置：Codex P2 + 独立评审三轮共 12 项 BLOCKING（含两轮余留驳回：Tier-2 规范比较、字典快路径不生效 O(k²)、running 翻转掩蔽、math 执法统计量误引与规则误托先例）逐项修复并五轮复测（v1→v5 每轮六对全分离幅度一致）；候选 94+1 SKIP（Linux）/95（Mac）全绿、基线按设计 13 PASS 后 4 MISMATCH + exit 132/133；portable 10/10（v5）、提交树重建逐字节一致（342d0e11）、Mac 产品构建+5/5 冷启动+静机 math 复测 passed（真实门槛 best_ratio 1.0026/1.0048；CI ef3def0 失败实为 best_ratio 1.1953 受基线单轮离群值驱动、1627582 为 GUI app 180s 超时，均取证归档）；伪影披露程序化计算：display_messages_workspace 九组逐对数组 ±3 打印格双向抖动、Linux edit-lines 四版摆动（v1 -24.3～-15.9% → v5 -0.1～+2.1%，v4 六行正向超 spread 全属该族且 v5 归零）归布局伪影推断、v1/v3 报告失实表述全部勘误；prefix(320) 立项前粗筛否决入否定清单（ERRATUM + 重跑验证日志）；四轮复核全部收尾（N7/N8 逐字修复并与复核方独立重算逐值一致，按机制免新复核轮）；CI 于 fd25e14 与重跑后的 9c6e2a1 均 15/15 绿——本 PR 三次 GUI 超时（reading-design 60s、math app 180s、acceptance streaming 120s）均判共享 runner 抖动并取证，math 另有静机真实门槛复测 passed（best_ratio 1.0026/1.0048）佐证 | [round-12](2026-11-14-round-12.md)；[归因](round-12/macos-xctrace-streaming-activity-attribution.json)；[math 取证](round-12/ci/head-ef3def0-math-typeset128-analysis.json)；[#334](https://github.com/chenweigao/perch/pull/334)，merge=8f92c27（15:56） |
| 13 | 2026-11-14 | SessionEditStats.tally 借用索引遍历（去迭代器逐元素拷贝） | **不采纳（候选已撤回）**：Mac edit_stats@6400 -1.65%（最差对 +0.47% 正向、spread 3.91%，区间重叠低于噪声带），@1280/@320 持平，Linux 持平（-0.32%/-0.20%/+0.40%）；归因依据扎实（Mac activity 测量段 IndexingIterator.next() 8.64% self）但未转化为收益——self-time 占比不等于可转化量，教训入否定清单；Mac edit64_bulk +12.07% 超 spread（场景选择性、64/512 子集其余 18 行全在 -2.40～+1.26% 带内，布局伪影嫌疑——round 10 同签名且当年未作机制结论——按 round-10 先例作回归信号处置、强化否决）；activity_init@320 中位数 +1µs（逐对 [+1×5,-1]，打印格级，非均匀位移——复核 B1 更正；路径被触，不能完全排除 codegen 效应）；等价性零变化：既有四处钉死两侧全绿（94+1 SKIP/95 PASS）、全 fixture checksum 逐字节一致；Linux 基线二进制与 round-12 Linux 候选逐字节相同（确定性构建，Linux 范围；Mac 跨轮构建上下文不同不主张）；Codex 2 P2 + 独立评审 3 BLOCKING（B2/B3 数字转写 a90ae8b 已修、B1 均匀性表述及精确项逐字更正）全部处置且重算一致；本 PR 期间共享 runner GUI 抖动六例（reading-design/math parse/acceptance streaming/dashboard 录制/task-context 反射/navigation-turns hover 断言竞争——后者以 main 同树 run 全绿为判定依据）全部经同 head 重跑或静机复测化解，dfd8c36 重跑 15/15 绿后合并；停止规则计数 1/3 | [round-13](2026-11-14-round-13.md)；[补丁](round-13/rejected-tally-walk.patch)；[数据](round-13/macos.json)；[#335](https://github.com/chenweigao/perch/pull/335)，merge=6c8241c（17:08）；[CI 取证](round-13/ci/) |
| 14 | 2026-11-14 | 状态栏工具列表免完整投影（tools-only 投影出口） | **已采纳/合并：Mac single_turn_activity@2000 -37.16%**（1.2150→0.7635ms，spread 7.55%，六对全分离，最差对 -36.21%），@400 -36.69%、activity_init 三档 -33%；Linux 筛选 -36.34%/-34.00% 同向分离、streaming conversation_activity 段 -28.57%（六对差值一致）；归因：ToolVisibilityProjection 帧占 activity 测量段 18.3%（round-12 复剖），机制为每次状态栏派生以全新实例走完整 update()（part 拷贝入字典 + 整轮 normalized 消息重建 + Snapshot）；改动：visibleTools 静态出口——calls/results 记位置不拷 part、直接产出，顺序/值逐点复刻（首槽位末数据、orphan 位置、live 观察序、位置身份、状态矩阵），其他投影调用方零改动、AgentWorkbench 零差异；钉死：checkActivityToolsMatchProjection 仅用既有 API（matched baseline 可编译且全绿），9 手工场景 + 2000 种子差分（评审方独立重放：1982/2000 非空、六状态全覆盖）+ 语料非空占比断言；两侧检查全绿**无预期失败**（95+1 SKIP / 96 PASS）、portable 10/10、重建逐字节一致（29f05887）、两端六对无正向超 spread 行（中位数口径；单对可越界、无方向一致性）；披露：find_bar +3.64% 为 ±2 打印格抖动（逐对 [+20,0,+10,0,0,+10]µs，路径零改动）、Mac conversation_activity 0.00% 系 0.01ms 打印网格分辨率不足（Linux 细刻度同段 -28.57%）、activity_init 小值档 spread 为 0.001ms 刻度效应；独立评审 VERDICT: CLEAN（3 非阻塞=记录精确性与单轮契约边界反例记录，已照改免新复核轮）；Mac 产品门槛 build+5/5 冷启动通过；924b3ef CI math typeset-32 失败（best 1.2672/中位数 1.6018、两变体轮间摆动近 2 倍）经 b6fe994 静机同口径复测判定 runner 噪声（best_ratio 0.9701/1.0089/1.0045 全过、status passed），b6fe994 CI 15/15 绿 | [round-14](2026-11-14-round-14.md)；[数据](round-14/macos.json)；[#336](https://github.com/chenweigao/perch/pull/336)，merge=9c12eb9（18:18）；[math 取证与复测](round-14/ci/) |
| 15 | 2026-11-14 | edit-stat 行计数 8 字节 SWAR 扫描（LF 总数−CRLF 对数） | **已采纳/合并（采纳数据 v2=3f255da）：Mac edit_stats@6400 -39.04%**（2.5040→1.5265ms，spread 10.60%，六对全分离，逐对 -0.901～-1.069ms），@1280 -39.10%、@320 -40.62%；Linux 六对 **+31.08/+32.10/+31.33% 一致性回归**（三档齐一、区间分离 spread≤2.45%；edit-lines 行位行 +22～+34%、bulk +36.6/+59.5%，超 spread 20 行全列）——定位按评审 B3 更正：普通非 bulk 的 edit-lines 行走未改动 fullLineDiff、属 round-8 布局摆动家族（推断；bulk 行走两计数快路径、确调 lineCount，其回归与上下文内 lineCount 成本方向一致——推断），edit_stats 回归与上下文内 lineCount 聚合成本相容（推断；复核更正调用路径表述：每轮一次 Edit 经快路径调 lineCount 两次+每五轮一次 Write，归一化 ~0.78µs/轮），机制未解、未做指令级取证；按"Linux 筛选、Mac 仲裁"规则采纳并全量披露；测量迭代 v1=c8dffd3 → 评审 **BLOCKING B1 正确性缺陷**（减法型 has-zero 掩码借位传播假标记：LF+VT/CR+FF 三个比特级反例）→ v2=3f255da 换无进位精确掩码 `~(((x&0x7F…)+0x7F…)|x|0x7F…)` + 钉死扩展（27,885 例：22,302 含 VT/FF 字节、16,811 含 LF→VT/CR→FF 危险邻接——复核后增设邻接专用计数器、反例逐字收录、0…12 偏移×跨字×尾部网格、双覆盖守卫；**未修复构建红跑 exit 132 归档+复现溯源清单、修复后全绿**）；两侧检查全绿无预期失败（96+1 SKIP/97 PASS，基线/候选 stdout 逐字节相同——确定性文本）；复剖（base=9c12eb9）：edit-stats 占 activity 测量段 64.1%（lineCount 闭包 5.56%）、cold collapsedWhitespace 余 24.4%、streaming search 52.1% 为首查询冷搜构成（评审核实 35 查询=1 冷+34 温、find_bar 只计温）；粗筛#1 collapsedWhitespace 字节重写等价 PASS 但 +16.56% 更慢否决入否定清单；粗筛#2 SWAR Mac -69.2%/-66.8% 通过（掩码缺陷 Addendum 2 补记、NB4 边界组限定更正）；NB5 分类器浮点假阳性修复（2 位小数舍入）；portable 10/10（v1 产品态；v2 产品差异仅掩码一条 OR）、提交树重建逐字节一致（dbc21b2e）、Mac v2 无正向超 spread 行（stage_narrative 中位数位移 +10µs、逐对 [+10,0,-10,0,+10,+10]µs 混合非均匀——复核发现 1 更正；量化/布局家族解释为推断）；**教训入否定清单：孤立微基准两个方向都不可外推，机械类候选必须双端上下文内粗筛**；复核（52a81ab）确认 B1/B2/B3/NB4/NB5 全部修复到位（掩码 256 字节值+458,752 相邻组合穷举验证、钉死语料独立重放一致、76+77 指标独立重算一致、红线/卫生通过），新 1 BLOCKING（stage_narrative 均匀性表述失实）+3 非阻塞（调用路径表述/覆盖计数标签/红跑溯源清单）均为逐字更正与证据补强类、已照改并自算验证（无产品变更，按机制免新复核轮）；最终 head 两端检查重跑全绿；CI 15/15 绿@22f0eb1（f589f4c/52a81ab/22f0eb1 三 head 的 run 均全绿、零重跑零门槛改动）；Codex P2（与独立评审 B1 同源：同一减法掩码缺陷与反例）已修复并回复处置；停止规则计数 0（round 14/15 连续采纳） | [round-15](2026-11-14-round-15.md)；[数据](round-15/macos.json)；[粗筛](round-15/screening/)；[复剖](round-15/attr/)；[#337](https://github.com/chenweigao/perch/pull/337)，merge=15f612f（21:32） |
| 16 | 2026-11-14 | 裸 URL 数据检测器改喂连续 UTF-16 存储输入（find-bar 冷首搜） | **已采纳/合并（采纳数据 v2=413bf86）：Mac find_bar_cold_query -18.98%**（1606.67→1301.78ms，spread 1.35%，六对全分离，最差对 -18.70%，逐对 -299～-319ms 高度一致；v1@9e7bc19 -19.75% 迭代幅度一致）；Mac 全部 81 项指标零正向超 spread、温路径 find_bar_query_update 0.00%；Linux 侧 canImport(Darwin) 守卫构成**无变化护栏**（cold +0.42% 带内）；Linux 15 行 edit64/512 正向超 spread（+5.2～+31.2%）= 已登记布局摆动家族（Linux 语义可证未变：Darwin 守卫+双侧摘要一致+fixture 一致；ab3→ab4 自然对照 edit64_first +0.55%→+19.93%；推断、全量披露）；归因（新冷查询专剖：中位 1597ms@16k 消息窗、21,067 样本、**最近命名产品帧归属**，方法脚本归档）：linkMatches（NSDataDetector 全链路）**总归属 66.6%**，其中七个桥接/DD 热点叶帧小计 26.6%（_nativeGetIndex 的 97.6% 归 linkMatches，桥接经 character(at:) 895 与 getCharacters 898 两个入口——复核发现 1 更正初版"~26% 总归属/单一入口"表述）、ReplyDocument.parse 14.05%、ConversationSearch.search（查询匹配红线域）6.02%——**round-15 曾把该 52% 区域整体归为 CF 语义红线，本轮据调用点级归因重画边界**；产品面：查找栏每次打开（@State 实例随栏销毁）+ 工作区历史搜索每键每会话（HistorySearchWorker 每查询新建实例）支付全窗冷搜；粗筛#1 haystack 物化**否决**（等价 PASS 但 CJK 查询 +13.5～+21.8% 更慢/ASCII 全变体 -3.9～-25.0%——CF 对桥接 Swift 串有 UTF-8 直读快路径，脚本依赖，入否定清单）；粗筛#2 检测器输入物化通过（d1 -34.8%、156 组等价 PASS、__NSCFString 往返保真探针）；改动：ReplyDocument.linkMatches Darwin 分支单点（CFStringCreateWithCharacters 物化+空串直通；Linux regex 回退零改动；AgentWorkbench 零差异）；钉死：checkLinkScanContiguousUTF16——parse 输出规范化序列化 + 3,000 文本 fuzz 语料**按平台黄金摘要**（在未改产品上捕获：Mac 97e345c9/Linux 5dd61f86；两后端边缘形态合法分歧——Darwin 卷尾随 CJK 入 URL、粘连 "xhttps" 视为未知 scheme，Linux regex 均不）+ 结构固定例（跨 URL 的 $ 对保持字面、math/URL 共存、链接文本守恒）+ 确定性双跑；**Mac base==cand 同摘要 = 等价直接证明**；固定例初版编码粘连形态仅 Mac trap（exit 133@49 PASS，双侧探针取证后改 CJK 分隔形态，先于任何测量，日志归档）；检查两侧全绿无预期失败（Mac 各 98 PASS/Linux 各 97+1 SKIP）、portable 10/10（9e7bc19 dirty=false）；伪影如实披露：Linux 首次尝试因构建树先删 → checkRemoteSetup #filePath 探针 trap（harness 伪影、双侧一致、发生在新钉死通过后；修正后整侧从零重跑 ab2/）；Linux clean 重建字节不可复现（环境级构建非确定性、双侧一致出现；降级为源状态核验+六对哈希恒定+黄金摘要验证链）；新 bench 指标 find_bar_cold_query（StreamingBench 夹具改动两端同一、hash 在案；测量置于全部既有指标后不扰动）；汇总器统计定义先对 round-15 双 JSON 153 项指标自校验零失配（复核方独立重算全部 165 项亦零失配）；**CI 取证与钉死迭代**：26502b5 core-regression 失败=钉死 v1 的 Darwin 黄金摘要在 CI runner macOS 构建 trap（DataDetectors 版本依赖，exit -5 工件归档 round-16/ci/）——非产品缺陷；bcbdd91 改 Darwin 侧为**运行时检测器差分断言**（3,016 文本惰性 vs 物化逐项相等，版本无关），Linux 黄金保留（语料/种子/digest 不变）；复核发现 1（BLOCKING，归因表述）修正产品注释（4f0ea7b，仅注释但二进制字节移动）→ 413bf86（钉死差分块元组数组无 == 的 Darwin-only 编译错误修复，Mac 门控首建拦截）→ **A/B v2 双端全量重跑于 413bf86**：Mac -18.98% 六对全分离、81 项零正向超 spread、checks 98/98（差分 3,016 文本双侧通过）；Linux 候选重建字节一致恢复（f598dcb4）、主护栏 +0.42%；复核其余 9 项非阻塞（trap 时序收窄、spread 零最小值约定、重建因果假设标注、粗筛 ASCII 区间修正为 -3.9~-25.0%、fixture 清单归档等）逐项照改；portable 10/10@413bf86；Mac 产品门槛 26502b5 与 07127c6 双次通过（build 0+5/5+porcelain 0/0）；CI 15/15 绿@b731775——两段取证：26502b5 core 失败=钉死 v1 Darwin 黄金摘要的 CI-runner macOS 版本依赖 trap（bcbdd91 运行时差分修复）；b731775 首跑 math 门槛 1.2791@128 经静机复测（best_ratio 1.0077/0.9810/1.0014）判定共享 runner 噪声（rounds 12/14 同族、轮间 2 倍摆动+tick_gap 2.5 倍离群取证），同 head 重跑全绿，零门槛改动；停止规则计数 0（rounds 14/15/16 连续采纳） | [round-16](2026-11-14-round-16.md)；[数据](round-16/macos.json)；[归因](round-16/attr/)；[粗筛](round-16/screening/)；[CI 取证](round-16/ci/)；[#338](https://github.com/chenweigao/perch/pull/338)，merge=76940c0（02:26） |
| 17 | 2026-11-15 | normalizeDelimiters 入口守卫改单遍 UTF-8 字节扫描（contains(92) 快速拒绝 + 字节对扫描，不确定对回落原 grapheme 搜索） | **已采纳/合并（采纳数据 v3=66a94d5）：Mac find_bar_cold_query -8.55%**（1294.27→1183.62ms，spread 1.47%，六对全分离，最差对 -7.65%，逐对 -97.8～-113.2ms；迭代 v1 -8.06/v2 -8.27/v3 -8.55% 一致）；Mac 全部 80 项指标零正向超 spread、温路径 0.00%；**Linux 筛选端同向改善且更大：cold -11.34% 六对全分离**（守卫为平台中立字节扫描，corelibs grapheme contains 同样昂贵；粗筛 -12.7/v2 -12.79/v3 -11.34 一致）；测量迭代 v1=815aa65（纯字节扫描）→ v1 的 3 项 Linux 正向（single_turn_activity@2000/@400、token200_turn_projection——路径可证不含本改动调用）+ 温路径 +1 格信号 → **v2=3aad9b7 混合守卫**（保留 stdlib contains(92) 快速拒绝；与 v1 真值等同——有对必有反斜杠、合取项冗余；但 v1/v2 快速接受均缺前边界证明，由 v3 修正；黄金不变）→ v2 中三项正向全消并转负（-1.24/-0.75/-1.27%）、Mac cold@2000 +1.41%→+0.66%——机制假设获数据支持；Linux v3 仅余 2 行 crlf 正向（+2.46/+3.96，v2 曾 16 行）= 已登记布局摆动家族（edit-lines 路径可证不含本改动调用链，grep+复核方双确认；round-15 v2 全家族 +4.95～+59.52/round-16 ab4 +5～+31 同族；附加假设：候选/基线构建目录不同的 DWARF/布局敏感）全量披露；归因（四场景复剖@76940c0，方法脚本归档）：冷首查 1295.9ms 中 normalizeDelimiters 1,934 样本（9.1%）**其中 ~79% 为两个 grapheme 级 contains 守卫搜索机制**（工具输出源充满转义反斜杠全部命中搜索）；round-16 后 linkMatches 余 58.7% 为 NSDataDetector 内部语义（langid/DD 词法——检测输出即行为契约，事实红线）、_nativeGetIndex 8.51%→0.19% 物化上下文内验证成立；splitInline 3.7%、cold 场景 TimelineEntry.make 12.1%（未动过）入队列；等价论证（v3 终版；初版"仅后边界+反斜杠恒独立"表述被复核 F1 推翻作废）：ASCII 对字节邻接=Character 匹配必要条件（UTF-8 自同步）；快速接受须**双侧边界字节级证明**（后随 ASCII/EOF 且前驱 ASCII/串首——Prepend/Extend/SpacingMark/ZWJ 标量全非 ASCII、CR×LF 不吞反斜杠；复核方 488,281 字节序列独立穷举零失配）；任一侧非 ASCII ⇒ 回落各平台自有搜索；**旧守卫/扫描不对称角落**（延长括号单独出现保持字面 vs 混合时字节级 Boundaries 照转）逐位复现并入钉；钉死：checkNormalizeDelimitersByteGuard——结构例 + 3,000 fuzz 黄金摘要 **d90ac2cad4b58020 单一跨平台值**（语料规避 URL 形态 ⇒ 两链接后端不参与 ⇒ CI 可执法——round-16 版本依赖教训制度化；未改产品捕获、Mac/Linux×基线/候选四方一致）+ 确定性双跑 + 转换密度守卫（412/3000>100）；双端上下文内粗筛先行通过（Mac -8.4%/Linux -12.7%，3/3 分离）；两端检查全绿无预期失败（Mac 各 99/Linux 各 98+1 SKIP，基线=旧守卫过全部新断言=等价直接证明）、portable 10/10@66a94d5、六对哈希首末恒定（Mac 5c908571/10f48e97、Linux de4f73b1/a6958765）；Linux 候选 clean 重建连续第三轮字节一致、基线侧环境级非确定性第四次如实披露（因果为假设）；**独立评审（2264a55）BLOCKING F1=快速接受未证反斜杠前导 Character 边界**（GB9b Prepend 反例 U+0600+"\(x\)"：融合致 contains 不中、源须字面，初版误纳转换；仓库 ConversationProjection 早登记同危险）→ 修复 66a94d5：快速接受须双侧边界字节级证明（前驱 ASCII/串首——Prepend 标量全非 ASCII、CR×LF 不吞反斜杠），不确定对回落各平台自有 contains；处置中实测发现 Linux corelibs 既有分歧（搜索无 GB9b→转换、字素迭代有 GB9b→无 math）按平台条件断言钉死旧行为（探针记录归档）；F4 钉死改精确 cmark 反转义文本断言（!hasMath 抓不到误纳）；F6 因果措辞限定、F8 round-15 区间精确化（+4.95～+59.52）、F9 档案卫生三项均更正；产品实质变更 → v3 双端全量重跑（本报告数据）+ 按机制派新复核轮；Mac 产品门槛 2264a55 通过（build 0+5/5+porcelain 0/0）、CI 15/15 绿@2264a55（新黄金钉死在 CI macOS 构建首次执法通过）；Mac 产品门槛 2264a55 与最终 head 9e1eb88 双次通过（各 build 0+5/5+porcelain 0/0，日志归档）；**复核（9e1eb88）VERDICT: CLEAN**（F1 修复经 488,281 字节序列独立穷举确认；F9 残留脚本头/F10 三处过期等价表述随收尾提交终清）；CI 15/15 绿@2264a55/9e1eb88/3ac42fb（3ac42fb docs-only 首跑 math 门槛 1.1635@128 边缘越线——同产品字节已于 9e1eb88 全绿、轮间摆动 1.4～2.2 倍，判 runner 噪声同 head 重跑全绿；未重复静机复测的判断依据归档 round-17/ci/）；停止规则计数 0（rounds 14-17 连续采纳） | [round-17](2026-11-15-round-17.md)；[数据](round-17/macos.json)；[归因](round-17/attr/)；[粗筛](round-17/screening/)；[CI 取证](round-17/ci/)；[#339](https://github.com/chenweigao/perch/pull/339)，merge=a13aee2（05:59） |
| 18 | 2026-11-15 | TimelineEntry visible() 的 trimmingCharacters 判空 → 零分配 allSatisfy(whitespacesAndNewlines.contains) | **不采纳（候选撤回，产品零改动）**：Mac cold@2000 **-0.07%**（6.7250→6.7200ms，worst +3.90%、spread 4.37%——变化为噪声带 1/60，逐对分布完全重叠），cold@1000/500/100 全带内、find_bar_cold_query +0.08%、**Mac 80 项零正向超 spread 且零回归**（连 round-10 式回归信号都无，纯中性）；Linux cold 四档 **-53.96～-55.20% 六对全分离** + find_bar_cold_query -2.20%（搜索每查询调 TimelineEntry.make）——**round-10 否定清单条目同构复现**：corelibs trimmingCharacters 走 UTF-16 物化为 Linux 特有开销、Apple Foundation 两端扫描即止近乎免费，按红线"Linux 特有开销不算产品收益"否决；输出等价双端实测（mode-1 行数/部件/字节全等、Mac 非空校验 ROWS_IDENTICAL_NONEMPTY、双侧 checks 全绿 Mac 99/Linux 98+1 SKIP、六对哈希首末恒定）；归因洞见（复核更正表述）：visible() 的 376 样本（1.8762%）是 **Mac 调用点归属桶（含被调；以 visible 为叶仅 9 样本）**而非 self-time，且属 Mac trace——教训为**归属占比低不保证系统性成本低**（round-13"self-time 不保证可转化"的镜像），跨平台可迁移性仍由 Mac 仲裁裁决；flush 主体（每 part 构造 KimiMessage(content:[part]) 的结构性 ARC/malloc）评估为高风险未选；Linux 15 行 edit64/512 正向（+6.8～+31.4%）= 已登记布局摆动家族（路径可证不含本改动）；harness 伪影如实披露：Mac 粗筛首次拷贝二进制被 SIGKILL（exit 137）→ ROWS_IDENTICAL 空==空假阳性 → 原地重跑+非空断言（教训入否定清单）；停止规则计数 **1/3**（rounds 14-17 连续采纳后首个不采纳轮）；独立评审（df8ccb8）确认否决成立（165 项指标+120 份日志重算零失配、等价性实现级论证：Apple 按 scalar 裁剪/corelibs 按 UTF-16 unit 扫描、26 成员 BMP 集合下两谓词无反例）+2 BLOCKING 文档更正（self-time 误标→"Mac 调用点归属桶、以 visible 为叶仅 9 样本"；门槛行误引粗筛哈希→正式 16b851bd/ceca9c9d）+5 非阻塞（JSON 粗筛元数据纠错、Mac 行数档补全字段、SIGKILL 现场复跑再证 exit 137、卫生、**F7 计数更正：round-2 已否决同函数变体、本轮为家族第三数据点+选题未反查否定清单的流程失误披露**）全部照改（0d06a53）；CI 15/15 绿@df8ccb8/0d06a53 双 head 零重跑；Codex 零发现 | [round-18](2026-11-15-round-18.md)；[数据](round-18/macos.json)；[撤回补丁](round-18/rejected-visible-whitespace.patch)；[粗筛](round-18/screening/)；[#340](https://github.com/chenweigao/perch/pull/340)，merge=89e5976（07:28） |
| 19 | 2026-11-15 | splitInline 美元守卫改字节级扫描（contains("$") → utf8.contains(36)；超集+保值无操作不变量等价） | **已采纳/合并（采纳数据 v2=1f9b5d4，含复核处置字节）：Mac find_bar_cold_query -5.93%**（1185.56→1115.21ms，spread 1.73%，六对全分离，最差对 -4.98%，逐对 -58.37～-78.89ms；v1=fe17ef1 -5.58% 逐对 -74.84～-60.60ms——复核 F4 更正误植端点——粗筛 -5.75%，三次独立测量幅度一致 0.35pp 内）；Mac v2 全部 80 项指标零正向超 spread（80 vs 81：stage_retained_cost 按全零打印格规则掉出，v1 仅因单对 0.01ms 刻度存活）、温路径 0.00%；**Linux 筛选端同向更大：v2 -9.54% 六对全分离**（610.88→552.60ms，逐对 -55.79～-60.57ms，与 v1 逐位同幅）（守卫平台中立；旧守卫实为 grapheme 感知 Foundation 子串搜索 StringProtocol.contains<A>→range<A>——复核 F3 更正表征，两平台同贵）；归因（复核 F1 BLOCKING 更正后唯一口径，重算脚本归档 round-19/attr/）：round-17 纯冷 find-bar 专剖 21,222 样本 inclusive 归属——含 splitInline 闭包帧 1,199（5.65%）、其叶方向 StringProtocol.contains 1,163（5.48%），语料无字面 math；round-17 报告的 795/3.7% 为不可复现的归属桶计数，已全点替换；增益与归属份额一致（-5.58% vs 5.65%），初版"超归因/每字节成本更高"表述撤回（样本份额×墙钟比较不能建立每字节成本论断，机制读法仅 HYPOTHESIS）；等价论证（不变量口径）：0x24 UTF-8 自同步且一切旧搜索形态需该字节 ⇒ 字节缺失拒绝集重合（准入为超集）；凡 Characters 无裸 "$" 的 run 在 split() 下保值无操作（零命中、终点 flush 单 run 值相等）——准入分歧无关紧要（探针实证：全融合 Prepend 形态 macOS 旧守卫拒/corelibs 缺 GB9b 准入，输出仍逐位一致）、无需平台回落；钉死：checkSplitInlineByteGuard——结构例逐规则（货币/空白/CJK/融合开启符+裸未配对 closer 重描述/strong 穿透/代码隔离+兄弟对）+ **全融合直调例 v2 新增**（\u{0600}$x\u{0600}$、$◌̈x$◌́：恰一 run、UTF-8 逐字节相等、旗标全保留——复核 F2）+ 3,000 fuzz **单一跨平台黄金摘要 5d1506ed4a822a53**（语料规避 URL 形态、运行时断言把守；未改产品捕获、四方一致；999/3000 提取）；双端上下文内粗筛先行通过（Mac -5.75%/Linux -10%，3/3 分离；Mac 二进制原地运行+非空校验）；选题按函数名/机制名反查否定清单无命中；两端检查全绿无预期失败（Mac 各 100/Linux 各 99+1 SKIP，基线=旧守卫过全部新断言；v2 钉死强化后 Linux matched 双侧 99+1 复证）、portable 10/10、六对哈希首末恒定（v2：Mac 415bf279/ce54227a、Linux 14e2b460/d68c1203；v1：Mac 0c84672a/80269d5a、Linux 5ff9465d/4d87a6ad）；portable 10/10（v2 产品树@256c097；v1@fe17ef1 并存）；Linux 候选 clean 重建字节一致 d68c1203 且**完整凭证留存**（复核 F7 处置）、基线侧非确定性第六次披露（因果假设；v2 起双侧留存重建退出码+源态+摘要+日志；v1 摘要 c93e8422 标注 operator-reported）；v2 黄金摘要四方一致（Mac/Linux×基线/候选）；Linux 正向：v2 仅 edit64_crlf +2.25%（v1 17 行 +1.20～+28.76%）——同一产品语义下家族振幅随构建摆动（round-17 v2 16 行→v3 2 行同型），本身即已登记布局摆动家族假设的最强佐证（SessionEditStats 无 ReplyMath 调用、grep 可证路径无关；采纳平台 Mac 零正向）；**独立评审（2f65eeb）1 BLOCKING + 6 非阻塞**（F1 归因口径/F2 结构例描述+全融合直调例/F3 旧守卫表征/F4 区间端点/F5 heading 不调用/F6 归档元数据/F7 重建凭证）逐项处置于 v2=1f9b5d4（评审方独立核验 166 指标/120 配对日志零失配、1,112,064 标量扫描零失配；A/B 采纳信号不受 F1 影响获评审确认）；产品/钉死字节移动 ⇒ v2 双端六对全量重跑已完成（本报告数据）；**复核轮（7518f45）1 BLOCKING + 3 非阻塞**（F1' INDEX 队列后记残留已撤回断言与未限定 3.7%/F2' 粗筛记录残留旧守卫表征/F3' CI 记录漏 math 失败与聚合器+归因强度/F4' JSON 夹具路径失实）——全部文档类逐字更正照改自证（免新复核轮；评审方独立重提取 240 配对日志、重算 331 指标/3,360 内层中位数零失配）；CI：2f65eeb（v1 产品态）与终 head 7518f45（v2 产品态）各 15/15 一次全绿；被替代 head 256c097 两个独立主失败（math unclosed_4096 ratio 1.5704——双侧 ~1.9x 轮间摆动、非门槛项全线候选更快；streaming 组 dashboard 夹具超时 capture-none 135.08s）+聚合器，判共享 runner 噪声家族并由终 head 同产品树双门槛通过实证确证（取证 round-19/ci/，评审方重算零失配）；Mac 产品门槛 2f65eeb 与 7518f45 双 head 通过（各 build 0+5/5+porcelain 0/0）；停止规则计数归 0（rounds 14-17、19 采纳） | [round-19](2026-11-15-round-19.md)；[数据](round-19/macos.json)；[粗筛](round-19/screening/)；[探针](round-19/checks/guard-admission-probe-record.md)；[#341](https://github.com/chenweigao/perch/pull/341)，merge=c085fd9（10:23） |

| 20 | 2026-11-15 | presentation-token narrative 段双机制候选（v1=NarrativeTextCache 文本表字节键消 NFC 规范化哈希；v2=L() 解析链精化：CFPreferences 单键读+规范标识符恒等捷径+静态 Locale 表） | **不采纳（双候选均被 Mac 上下文内粗筛否决，产品零改动，两项钉死按 round-10 先例保留）**：选题=presentation-token（19 轮后唯一未归因 bench 族；产品自带阶段仪表显示 narrative 段（ActivityNarrativeProjection.make）占 token 更新 **75.2～90.9%**、每 delta ~0.11ms 恒定与窗口无关——流式渲染热路径）；选题反查执行：lowercased() inclusive 仅 0.87% 粗筛前否决（caller 桶 3.6% 误读经下钻纠正——round-18 F1 陷阱再现）、cronFire trimmingCharacters 命中否定清单家族否决、Todo/TimelineEntry 结构性散点不选；**归因两次（脚本/输出/runner 日志归档 round-20/attr/）**：首跑（尾部池 24～8,417B、均值 4,220.5B harness，20,053 样本）make() 74.74%、String 键 NFC 规范化哈希 _normalizedHash inclusive **7,495=50.01% of narrative**（其下 Hasher._combine self 18.91%/_fastNFCCheck/withFastUTF8/getNormData）、调用链 NarrativeTextCache.value→Dictionary.subscript→find 样本级确证；**复跑（短尾 ≤262B、稳态循环缓存热画像，20,016 样本；复核 F3：缓存命中分布与 bench 首见 MISS 不同构，排序结论按此限定）机制排序反转**：NFC 哈希 inclusive 塌缩 6.68%（_rawHashValue 见证口径 7.49%；与 v1 粗筛 token2000 -7.68% 量级吻合）、**L() 默认参数帧 inclusive 6,002=56.71% + 主体帧 1,792=16.93%（帧集不相交）并集 7,794=73.65%**（初版"≈29%+"未定义叶桶小计作废；tryCast self 2.09%/inclusive 16.21%——初版"单叶 16.45"作废，复核 F2 显式定义口径；其下 persistentDomain(globalDomain) 全域物化+as?[String]、strcmp 3.93%、objc_msgSend 3.69%、CF retain/release ~4.7%、ICU ulocimp 2.31%——每 L() 付全域物化+两遍 preferredLocalizations+Locale 逐次构造；bench 每 delta 调 2-4 次）；**v1=1ac4f52**（ByteText UTF-8 字节等值+连续缓冲 SipHash、CleanKey 消插值键拷贝；等价=字节同命中不变、NFC/NFD 变体各自重算而派生规范协调+下游仅规范==/渲染观察）：Mac 粗筛 token200_narrative +2.83% 重叠、token2000_narrative -7.68% 逐对 3/3 同向但分布重叠、totals 重叠→否决（v1 Linux token2000_narrative 全分离 -2.83%=35 打印格——复核 F1 更正初版"全重叠/近打印格"失实；采纳只看 Mac，否决不变）；钉死捕获期发现：语料含规范变体对时未改产品与候选黄金**合法字节分歧**（726a…/db78…而 staged 计数一致）——按 round-17 先例变体对移出语料+结构例钉规范等价，收敛后黄金 **4e46d66eff016205 未改产品捕获、四方一致（逐字节相等）**；**v2=567529b**（无缓存设计——LocalizationChecks 直接写 UserDefaults 逐调用生效的行为钉死禁止缓存；三点精化保持逐调用活读；CFPreferences 读与恒等捷径 Darwin-only，**Locale 表无平台守卫 Linux 同样生效——复核 F4 更正初版"Linux 无变化护栏"表述**）：Mac 粗筛四项 token 中位数**全部重叠且反向，精确 +4.32/+3.10/+4.53/+2.63%（聚合 +2.6～+4.5%；复核 F1 更正初版 +4.8% 转写错误与 0.1986 离群归属）**（逐轮符号不一致=噪声带内；按 round-13 先例披露为弱回归信号）、Linux 零信号→否决；**56.71% inclusive 归属份额零墙钟转化**=归因≠可转化家族第三数据点（HYPOTHESIS：CFPreferences 进程内域缓存已摊薄物化成本）；验证环境披露：check-localization-runtime.sh 双侧 exit 137（WORKSPACE-DESIGN.md:166 早记录 mini SIGKILL 裸 swiftc 二进制；经查该脚本不在任何 CI 组）→SwiftPM scratch 编译验证通过；**.app 硬链接二进制仍 137（疑似 round-18 原地规则扩展：重定位含硬链接均被杀——操作员报告未归档、HYPOTHESIS，复核 F5 限定）**、浅 bundle 原地可跑但资源不加载（133 环境伪影，同为操作员报告）→钉死运行时载体移入 WorkbenchCoreTests（CI core-regression 仅 macOS 侧执法 Swift 钉死；Linux CI portable 组为纯 Python——复核 F7 更正"双平台 CI 执法"过述，Linux 分支本地验证）；**平台分歧探针**：corelibs Bundle.preferredLocalizations 完全忽略 preferences 恒返回首候选（6 组实测归档）、Apple 为 ICU 匹配——Linux L() 主体返回 value.resolved 不选束，但省略 locale 的调用在 Linux 同样求值默认参数解析链（声明在 #if 外——复核 F4 更正"永不走该链"），钉死按平台条件（round-17 先例）：Darwin 断言 ICU 语义+CFPreferences/persistentDomain 读一致性（v2 等价前提留证）、Linux 断言实测 legacy 行为防漂移；终形态 eb13b26：Sources diff 为空、Linux 101 PASS+1 SKIP、**Mac 终形态 102 PASS 原地跑（Darwin 分支钉死运行时首验+黄金 Mac 复证）**、portable 首跑 10/10@eb13b26（**dirty=true 如实披露，脏路径范围未记录**——复核 F6）+处置 head e5a80a4 清洁重跑 10/10（dirty=false）双件并存、既有三黄金完好；**方法学教训入否定清单：归因 harness 负载分布必须与采纳指标同构——含输入规模与缓存命中分布/预热选择**（24～8,417B→≤262B 尾部使机制排序 50.01%↔6.68% 反转；短尾稳态循环缓存热 vs bench 首见 MISS 不同构——round-15 教训的归因侧镜像，复核 F3 扩展）；粗筛制度化第三次在正式六对前拦下无效候选；**独立评审（f4025c0）4 BLOCKING + 3 非阻塞**（F1 粗筛数字转写失实/F2 归因 self-time 与 inclusive 口径混杂/F3 短尾画像非同构/F4 Linux 非绝对绕过 locale 链/F5 补充实验操作员报告未归档/F6 portable dirty=true/F7 钉死执法范围过述）全部文档/注释类逐字更正照改并自行重算验证（评审方独立重解析双 XML、重算 48 内层中位数、重放黄金 4e46d66e/1382/883、核验双补丁精确还原；按机制免新复核轮）；停止规则计数 **1/3** | [round-20](2026-11-15-round-20.md)；[归因](round-20/attr/)；[粗筛](round-20/screening/)；[探针](round-20/checks/)；[v1 补丁](round-20/rejected-bytekey-tables.patch)；[v2 补丁](round-20/rejected-lean-l10n-chain.patch)；[#342](https://github.com/chenweigao/perch/pull/342)，merge=a559cea（13:58） |

| 21 | 2026-11-15 | KB 级流式尾部测量面扩展（long-tail-stream 场景）+ 字节键文本表复测（v1 逐字复用 round-20 设计；v2 withUTF8 修复） | **不采纳（v1/v2 均被 Mac 粗筛否决，产品零改动；长尾场景与钉死保留为测量基础设施）**：停止规则计数 **2/3**；选题：行使 round-20 否定清单预留重试路径（先补 KB 指标再复测）；TimelineEntry.make 叶级评估放弃（ARC 散点 ~4.1% 上限+trim 家族+API 形变红线）、lowercased() 0.87% 粗筛前否决（caller 桶 3.6% 误读纠正——round-18 F1 陷阱再现）、cronFire 命中否定清单否决；**测量面扩展（68b0ce4，tests-only 保留）**：presentation-token 尾部追加 long-tail-stream 场景（round-16 find_bar 先例：置于既有测量后、合成夹具、hash 记录）——每更新尾部文本唯一（707→2,907B，MISS 分布保真=round-20 F3 教训制度化），基线 narrative 中位 1.0688ms ≈ 小尾场景 10 倍；汇总器 scenario 感知扩展经 round-19 双数据集逐字节零失配自校验；**归因三份（miss-heavy KB 画像：base/v1/v2，归档 round-21/attr/）**：base make() 86.85%、**phase 闭包（lowercased+32 contains）60.82%**、String 键 _normalizedHash 29.56%（find 3,088+insert 2,050）、ensureUnique/insertNew 各 ~11.8%；v1 侧 _normalizedHash=0 但 **ByteText 机制 24.30% of narr≈被替换份额**——陷阱在**等值**：ByteText.== inclusive 3,000 样本中 1,892（11.08%）为 elementsEqual 经 IndexingIterator 的逐字节 subscript witness；哈希侧 1,123/1,136 走 withContiguousStorageIfAvailable **快路径**、仅 9 样本回退（复核 F1 更正初版"每次哈希落入回退"失实概括，勘误 ERRATA E1）——**v1 Mac 粗筛 +0.68% 之谜的决定性解释**；v2（withUTF8 等值+哈希，mutating 陷阱经双平台探针拦截）ByteText 降至 9.51%、逐字节路径清零、phase 升至 75.07%；**份额-墙钟转化差距第三数据点（复核 F2 更正为并集口径）**：表机制命名桶并集（去重、单一分母）base **5,149=25.73% of all** → v2 **1,593=7.96%**（-17.77pp；初版重叠求和"~46%→~16%、预示 -30% wall、~1/7 转化"作废），实测 longtail wall -3.5%——差距解释保持 HYPOTHESIS：画像万次更新致表 8,192 驱逐重建+桶探针脱离 L1 vs bench 25 更新表 <150 条目 L1 常驻；**归因 harness 同构性累计四维=输入规模、缓存命中分布（round-20 F3）、容器规模/驱逐动力学、分支短路负载分布（复核 F4：画像基文本含"验证"第 7 谓词短路 vs bench 尾部零关键词 32 谓词全扫）**；phase 仍为最大单一机制（闭包 only 口径 54.61→73.36%）但**可迁移收益未确立**——round-22 若选此靶由粗筛裁决而非画像份额；粗筛：v1 Mac longtail +0.68% 重叠否决、Linux -2.97% 3/3（Linux-only 形态）；v2 Linux longtail **-5.53%/-5.11% 3/3 分离**、Mac 首轮 3 轮 -4.28% 重叠（token2000_narrative -9.5% 逐对 3/3）→ **扩展 6 轮**：六项指标全负（-1.88～-3.50%）逐对半数至三分之二（3-4/6）**全部重叠**、token2000_narrative 均值回归至 -2.52%（临界判定必须扩展复核，入方法学）——效应量全部位于实测 spread（8.29～21.84%）内；**另两处分离回归信号（复核 F3 更正初版"护栏无变化"漏报）**：Mac streaming narrative +6.25% 候选慢分离（0.16×3→0.17/0.17/0.18，打印格一位移、因果未诊断）+ Linux cold@2000 +0.48% 分离（48.35>48.17）——按 round-13 先例作回归信号处置强化否决；正式六对同 n 同协议可预期改善分类器不过 → 按 round-15 粗筛纪律否决不消耗正式轮（评审方独立确认"否决成立且非过早"）；全程等价钉死不动：黄金 4e46d66eff016205 于 v1/v2 候选侧、Mac/Linux、粗筛+checks 全链复证（Mac 双侧 102 PASS、Linux 101+1）；portable 10/10（561060e，dirty=true 范围明述=当时未提交的归档文件）；撤回提交 561060e 后 Sources diff 为空、AgentWorkbench 零差异；stdlib 热路径陷阱 ×2 入否定清单附注（UTF8View 逐字节 witness；withContiguousStorageIfAvailable nil 回退即热路径；正解 String.withUTF8）；迭代链 68b0ce4→a7332c8→2aa8d97→561060e 全保留；**独立评审（48bbceb）4 BLOCKING + 2 非阻塞**（F1 v1 哈希回退解释与画像矛盾/F2 inclusive 桶混同与重叠求和/F3 漏报两处分离回归信号/F4 phase 短路负载非同构+"28"应为 32+尺寸 114B～3.89B…3.89KB/F5 数字措辞/F6 归档脚本陈旧标签）全部文档类逐字更正照改并自行重算验证（本地重算与评审逐值吻合；历史证据以 round-21/ERRATA.md 勘误不改写；按机制免新复核轮）；CI 48bbceb 15/15 一次全绿 | [round-21](2026-11-15-round-21.md)；[归因](round-21/attr/)；[粗筛](round-21/screening/)；[撤回补丁](round-21/rejected-bytekey-withutf8.patch)；[ERRATA](round-21/ERRATA.md)；[#343](https://github.com/chenweigao/perch/pull/343)，merge=ed53341（16:03） |

| 22 | 2026-11-15 | narrative phase 关键词判定改单遍字节扫描（lowercased()+32 contains → NarrativePhaseScan：首字节折叠分桶+双侧边界证明+不可判定回落原谓词+CJK 兼容区整文回落 legacy 链） | **已采纳/合并（采纳数据 v3=4b9ac95，终 head 8f20783；初审+复核双轮全部闭环；merge=b11a7d5）：Mac longtail200_narrative -87.37%**（1.1796→0.1490ms，六对全分离，最差对 -86.30%，逐对 -0.9833～-1.0846ms；spread 8.75% 双侧分列 8.20/8.75）；token200/2000_narrative **-69.94%/-70.75%**、longtail_total -86.39%、token totals -63.73%/-53.92%——六项主指标全满足分类器；**Mac 88 项零超 spread 的正向中位变化**（单对例外 4 处全为 edit512_* 家族、中位带内，复核 F2' 口径逐一披露）；三次独立六对测量幅度一致（v1/v2/v3 = -87.27/-86.99/-87.37%）；Linux 同向 **-73.13% 六对全分离**（逐对 -0.7692～-0.7857ms）、**95 项零超 spread 正向中位**（单对例外 10 处披露，含打印格级 stage 微指标）、护栏全带内；归因=round-21 miss-heavy KB 画像 phase 闭包 only 54.61%（bench 尾部零关键词 ⇒ 32 谓词每 delta 全扫；短路非同构已披露——裁决靠粗筛+正式测量非份额外推）；**测量迭代 v1=e2ff3c0 →（初审 F1 BLOCKING：CJK 兼容表意文字规范折叠丢失匹配，真实行为回归）→ v2=e14c25d（兼容区整文回落 legacy 链 + 共享惰性 lowercased）→（复核 F1' BLOCKING：证据记录类——分解探针以规范 == 比较失实；匹配器行为零改动，评审方独立重放 17,943 输入零失配确认）→ v3=4b9ac95（采纳态；按 round-16/17 先例双端六对全量重跑）**；探针勘误（F1'）：`decomposedStringWithCanonicalMapping` 字节比较双端重跑确认 U+FA55→U+7A81、U+FA8E→U+641C、U+F96A→U+7D22、U+2F800→U+4E3D、U+F900–FAFF 区 **460 个字节变化标量**（与评审独立计数一致）、U+2F00 双端报自身——原探针"分解 API 不暴露单例映射"结论撤回（勘误体记录保留原件为历史证据）；**操作性规范等价穷举扫描保留且依据加强**（与旧规范搜索同一等价关系、不依赖分解 API 行为）：恰 3 桥（U+FA55→突/U+FA8E→搜/U+F96A→索）全在检测区间；F7' 同步：非 ASCII 规范等价于纯 ASCII **存在**（U+037E→';'、U+1FEF→'`'、U+212A→'K'）——概括撤回，关键词级论证保持（32 关键词不含这些字符，Kelvin 桥由小写扫描+无-k 断言覆盖）；等价四层论证：双侧边界证明（round-17 技术）无假阳性 + ASCII 桥穷举（唯一 U+212A→'k'、32 关键词无 k）+ CJK 规范等价穷举（3 桥全检出）+ 不可判定/兼容命中回落原谓词（GB9b 平台分歧逐位保留）；钉死 checkNarrativePhaseSinglePass（v3 态）：双穷举扫描 + 2,000 文本差分模糊（对照逐字复刻旧链、同平台差分即契约；碎片含四类 Prepend/Extend/ZWJ/词内组合符/İ/Kelvin/emoji/兼容区 6 形态；唯一前缀保证表冷——静态表跨实例存续；对抗文本 1,130、五类别密度守卫）+ 评审反例逐字（QZ0/QZ1/QZ2/QZ4）+ QZ5（F5' 表热修复：裸"冲U+FA55"与结构例"冲突"规范等价可表热命中不经兼容检测——改唯一 clean-stable 形态）+ 36 结构例 + 既有黄金 4e46d66eff016205 原样通过（覆盖边界 F3/F3' 口径：黄金=脏语料端到端，Prepend/组合符角落属差分模糊；收据按实际运行枚举——Linux 粗筛脚本不跑 checks 无收据不列入）；双端粗筛 v1/v2 双次全过（v2 精确百分比经 F4' 复核重算：Mac token -67.751849%/-72.199175%、Linux -58.962752%——初版系 driver 行 4 位舍入）；两端检查全绿无预期失败（v3：Mac 各 103/Linux 各 102+1，基线=旧链过全部 v3 钉死=等价证明）、portable 10/10 三态各一次（e2ff3c0/e14c25d/4b9ac95，dirty=true 范围明述）、六对哈希首末恒定（v3 Linux 56e803fe/4dd0667b）、Linux 候选 clean 重建字节一致 4dd0667b+凭证留存、基线侧非确定性**第九次**披露（da3fec15 vs 56e803fe，因果假设，凭证完整）；**初审（e6af380=v1 态）1 BLOCKING + 5 非阻塞**（F1 兼容折叠回归→v2 产品修复+全量重跑 / F2 resolves 四类各自 lowercased→单次惰性共享 / F3 覆盖清单过述 / F4 spread 归属逐跑双侧分列 / F5 派生数值未舍入中位 / F6 Linux 零正向限定+单对越界披露）——评审方独立重算 183 指标/120 日志/19,200 计时值、重执行全部扫描+87,648 附加边界例；**复核轮（1af7453=v2 态）1 BLOCKING（证据记录类，明示不阻塞匹配器行为）+ 6 非阻塞**（F1' 探针勘误 / F2' 单对例外 7+1 处→统一"零超 spread 正向中位变化"+逐一披露 / F3' 覆盖收据按实际运行 / F4' 粗筛百分比复核 / F5' QZ5 表热 / F6' INDEX v1 残留→迭代历史标注 / F7' ASCII 规范化概括撤回）——评审方独立重算 184 指标/120 v2 日志/19,200 计时值/1,200 edit-lines 内层中位数、原生重执行双穷举扫描、2,000+15,943 输入重放对照零失配、29 关键词字符对 Kangxi/补充区等价与组合可能性逐一核验、withUTF8 连续性与检测端点核验（F0 AF 实覆盖 2F000–2FFFF，保守超集安全）；v3 逐字更正+自行重算验证（探针/百分比/单对例外均本地复现吻合），按机制免再一轮复核；CI：e6af380 首跑 math typeset-32 best_ratio 1.2330 失败（轮内摆动 1.72x/2.36x、候选离群轮 193.9ms、SwiftMath 与本改动无调用路径）→ **静机真实门槛复测 passed（1.031）** → 同 head 重跑 **15/15 全绿**；1af7453 **15/15 全绿**（取证+复测+fresh-dir 护栏伪影归档 round-22/ci/）；Mac build+Aqua 5 冷启动 e6af380/1af7453/8f20783 三 head 通过（各 build 0+5/5+porcelain 0/0；日志归档）；8f20783 CI **15/15 全绿**一次通过；mergeable CLEAN 确认后按零介入授权合并（停止计数归 0）；产品面=流式渲染每 delta 状态行/叙事派生（KB 级无关键词回复=32 谓词全扫最坏情形=真实流式常态）；停止规则计数**归 0**（rounds 14-17、19、22 采纳；20/21 中断被重置） | [round-22](2026-11-15-round-22.md)；[数据](round-22/macos.json)；[v3 证据](round-22/v3/)；[v2 证据](round-22/v2/)；[粗筛](round-22/screening/)；[探针勘误](round-22/checks/compat-decomposition-probe-record.md)；[CI 取证](round-22/ci/)；[#344](https://github.com/chenweigao/perch/pull/344)，merge=b11a7d5（19:51） |
| 23 | 2026-11-15 | fullLineDiff 行比较字节区间化（字节相同确认 + 规范回落按需物化 Substring） | **已采纳/合并（Mac 仲裁；采纳数据 v2=8465aea，终 head 4514575；评审 8B+3NB 全部闭环；merge=1bcbc00）：v2 Mac edit512 五项主指标 -19.68～-20.81% 全部 6/6 分离**（unchanged/middle/insert/first/last，最差对 -17.38～-18.81%），edit512_unicode **-8.57%**、edit64_middle **-15.95%** 亦 6/6 分离——七项主指标全满足分类器；**Mac 88 项零超 spread 的正向中位变化**（单对例外 6 处：edit64_canonical P1 边界越带 + 5 处 projection 族 P2/P4/P5 散布、路径不经 SessionEditStats，F2' 披露）；Linux 主指标七项 6/6 分离 **-44.59～-52.54%**；95 项中正超 spread 仅 **edit512/edit64_crlf +3.84%/+2.18%（6/6 正向）——走未改动的探针路径**（CRLF 单行整文比较、>1024B 不进 fullLineDiff；产品 patch diff 核验不触该代码；语义可证同一，归已登记 Linux edit-lines 布局敏感家族（round-8 否定清单 ±23～31% 摆动、round-16 处置先例），推断、未做指令级取证；Mac crlf 带内、v1 Linux crlf 亦带内——位移随 tests-only 二进制布局变化出现）；**测量迭代 v1=3ba1f1a →（独立评审 8 BLOCKING：全部证据记录/表述类+钉死强化，评审方独立重放 45,425 JSON 解码差分对确认产品实现零行为缺陷、独立重算 183 项指标/120 份原始日志确认全部 v1 采纳数值、独立插桩重放真实分支访问 17,390/304/539、独立计算 activity fixture 路由 fullLineDiff 调用 0）→ v2=8465aea（tests-only：F4 变异杀手对+计数器语义注释，产品源零改动、产品 patch 逐字节相同）——按 round-16/22 先例双端六对全量重跑，按机制免新复核轮**；评审处置：F1 Mac 表七行中位数转写错误（本地重算逐值吻合更正）、F2 单对例外名称/数值错配（release_model_state 实为 P2）、F3 JSON 样本 6 位舍入破坏可重现性（v2 JSON 全精度+口径说明）、**F4 计数器为语料形态分类非分支执行计数（基线打印同值即证）+等长字节不同变异体可过 v1 全语料（其余规范等价对字节长度均不同、长度检查即分流）——评审逐字新增 2 个等长规范等价对（U+0340/U+0300 单例分解；NFC/NFD 互换等长行），本地自证变异体 exit 132 击杀**、F5 语料组成精确化（v2 态 773=19 结构+2 变异杀手+692 入选模糊（700 尝试 8 空跳过）+60 重复文本对，60 对中 40 对至少一端>1024B）、F6 粗筛 @320 打印格差值 [+2,+1,+5]µs 漏报 +5µs 更正、**F7 探针勘误**（v1 different-lines 案例 `acc && body()` 短路——全程仅 7 次调用，~0.4ns 作废；裸内存 ~1-2ns 从未测量、删除；v2 探针 XOR 全调用+64 对轮换索引防提升——首版常量输入被优化器提升测得 0.000ms 弃用；承重事实存续：跨 base 字节相同 ~16ns vs 规范等价 ~309ns 约 20 倍；产品每行成本不声称纳秒值）、**F8 canonical 处置绝对化撤回**（Edit API 不保证 old/new 同规范化，跨工具/显式规范化/混合文档可产生该形态、真实频率未测；47:1 仅合成语料比例；canonical bench 每行字节长度不同——失败于长度检查非逐字节循环；round-15 先例适用经评审确认正确）、F9 粗筛/正式 spread 分母口径说明、F10 参考端非整链逐字拷贝限定（lineDiff 加路由标签、lineCount 用另行钉死的标量回退）、F11 重建收据 porcelain 路径未留存（operator-reported 标注，路径清单协议自 round-24 起）；canonical 形态权衡终态：**v1 Linux 分离正向（+8.65%/+7.86%）未在采纳字节复现——v2 双端带内**（Linux +2.21%/+2.57%、Mac +2.82%；三读数全落 ~9-10% 噪声带）；主指标幅度 Linux v1→v2 位移（-39%→-52%，产品源同一）属布局家族、Mac 仲裁幅度 v1/v2 一致（差 0.4～2.9pp）；钉死 checkEditLineByteRangeDiff（v2 态）：公开 derive() vs 镜像改动前算法的参考端同平台差分，773 对 JSON 解码跨 base **零失配**+语料计数器（字节相同 14,507、回落相等 310/不等 12,880；四路由 265/218/281/9）**双端逐项相同**=种子确定性；执行覆盖由评审插桩重放+变异测试外部证明（计数器语义经 F4 更正）；既有冻结 Character-oracle 钉死全绿不动；机制探针（Linux swiftc -O v2 权威）：identity ~0.2ns、跨 base 字节相同 ~16ns、规范等价字节不同 ~309ns、不同行 ~13.5ns、裸循环探针形态 ~27ns（含每调用 withUTF8 开销，产品形态未单独测量）；Mac 计时探针未做（mini 裸 swiftc SIGKILL 限制）、由上下文内测量裁决；双端粗筛 3 对：Mac 主指标 3/3 分离 -8.73～-20.60%（canonical +4.48% 带内、edit_stats@320 打印格 3/3 信号正式未确认——v1 +2.00%/v2 +2.03% 带内，该路径经评审独立计算 fullLineDiff 调用 0）、Linux 3/3 分离 -29.79～-39.38%（Linux 粗筛不跑 checks——F3' 收据纪律）；两端检查全绿无预期失败（v2：Mac 各 104、Linux 各 103+1）、六对哈希首末恒定（v2 Mac 6a1d122f/4af2c749、Linux a6082167/1953eea1）、Linux 候选 clean 重建字节一致 1953eea1+凭证留存、基线侧非确定性**第十一次**披露（2e9a4930 vs a6082167，F7 收据协议，因果 HYPOTHESIS）；portable 10/10 双 head（bc2d93d dirty=true 范围明述 / 4514575 dirty=false）；Mac build+Aqua 5 冷启动 bc2d93d+4514575 双 head 通过（各 build 0+5/5+porcelain 0/0，v0.8.1-143/-145）；CI bc2d93d **15/15 一次全绿**；4514575 首跑 math 门槛失败（parse_unclosed_4096 ratio 1.7074>1.25）——取证：**同 Sources 的 bc2d93d 一小时前同门槛全绿（diff=0 行）**、候选早期轮全场景系统性膨胀而末轮回落至基线（1.09）、摆动 ×1.76~2.76、零调用路径关联、interaction job 仅为 math 聚合——同 head 重跑 **15/15 全绿**（round-12/14/16/22 先例，门槛零改动，取证归档 round-23/ci/）；mergeable CLEAN 确认后按零介入授权合并（停止计数保持 0，rounds 22/23 连续采纳）；否定清单反查完成（非 round-7 lazy cursor 家族——算法结构不变仍先物化后扫描、物化对象降为 Range；非 trim/字节键/L() 链/物化 haystack 方向；评审确认未删任何 stdlib 快速拒绝守卫、AgentWorkbench 零差异、既有测试仅注册行）；红线：Linux 特有开销/收益均不计入产品口径（对称适用）；产品面=状态栏每快照编辑统计与更改页每轮标记（真实 Edit old/new 共享上下文行=字节相同主导，bench 与产品负载同构、JSON 解码跨 base）；停止规则计数**归 0 保持**（round 22/23 连续采纳信号） | [round-23](2026-11-15-round-23.md)；[数据](round-23/macos.json)；[探针+勘误](round-23/probe/)；[粗筛](round-23/screening/)；[正式 A/B 证据](round-23/ab/)；[CI 取证](round-23/ci/)；[#345](https://github.com/chenweigao/perch/pull/345)，merge=1bcbc00（23:00） |

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
- 绕开 Foundation 字符串裁剪/扫描的一类候选（`trim(...).isEmpty` 早停、
  `trimmingCharacters` 前的 O(1) 守卫）：Linux corelibs 大幅受益（round 10 冷投影
  -17.89%），Mac CFString 无超噪声改善（-0.96%）。round 2 已记过同一机制，round 10
  在不同位置重演。此类候选先在 Mac 上跑一对目标场景粗筛再决定是否投入整轮，
  不要把 Mac 复测放到最后（round 10）。**round 18 再次实锤**（TimelineEntry
  visible() 的 trimmingCharacters 判空 → 零分配 allSatisfy；**round-2 已
  否决同函数判空的标量早停变体**——round 18 为同机制家族第三个数据点，
  并暴露选题流程失误：归因选靶后未按函数名反查本清单）：Linux cold 四档
  -54～-55% 全分离 + find_bar_cold -2.2%，Mac cold@2000 **-0.07%**（spread
  4.37% 的 1/60，80 项零正向零回归）——按本条否决撤回；凡以"消除
  trimmingCharacters/trim 开销"为机制的候选，Mac 粗筛不分离即止步。
  配套 harness 教训（round 18）：Mac 上被测量的二进制必须**原地运行**
  （拷贝到别处会被 SIGKILL、exit 137——处置时现场复跑再证），等价/正确性
  校验必须**断言非空**（否则空==空的假阳性会掩盖整批无效测量）；**选题
  流程教训（round 18）**：归因选靶后、粗筛前，必须按函数名与机制名反查
  本否定清单（visible() 早停变体 round-2 已否决在案）。
- **归因 harness 的负载分布必须与采纳指标同构——含输入规模与缓存命中
  分布/预热选择**（round 20，复核 F2/F3 更正口径）：presentation narrative
  段首跑归因用 24～8,417B（均值 4,220.5B）尾部池，String 键 NFC 规范化
  哈希 inclusive 占 50.01%；采纳指标（token bench）尾部实际 ≤262B，同机制
  塌缩到 6.68%，机制排序完全反转（短尾下最大单一归属=L() 默认参数帧
  inclusive 56.71%）。且短尾画像为稳态循环、静态表全热，而 bench 30 个
  测量更新皆首见 MISS——命中分布亦不同构，其排序结论按此限定。归因
  harness 的输入规模/形态/预热必须先对照 bench 夹具核实，再谈机制份额；
  这是 round-15"孤立微基准两个方向都不可外推"在归因侧的镜像。
- **NarrativeTextCache 文本表字节键化**（round 20 v1）：消除 String 键 NFC
  规范化哈希（ByteText UTF-8 等值+连续缓冲 SipHash+CleanKey 消插值键）——
  等价论证成立（黄金 4e46d66eff016205 四方逐字节一致、NFC/NFD 结构例
  钉规范等价），但机制仅对 KB 级尾部文本成立：Mac 粗筛 token200_narrative
  +2.83% 重叠、token2000_narrative -7.68% 逐对 3/3 同向但分布重叠——bench
  采纳指标不敏感，否决；KB 级尾部的墙钟收益**未测**（非已证伪，复核
  F3 限定）。勿在 bench 尾部形态不变的前提下重试；若未来指标覆盖 KB 级
  流式尾部（real-stream 族）可凭本轮等价设计与钉死直接复用。
- **L()/AppLanguage 解析链微优**（round 20 v2）：短尾稳态画像下 L() 默认
  参数帧 inclusive 56.71%（并集 73.65%）of narrative 段（persistentDomain
  全域物化 tryCast inclusive 16.21%+双遍 ICU+Locale 构造；复核 F2 定义化
  口径），CFPreferences 单键读+规范标识符恒等捷径+静态 Locale 表三点
  精化后 Mac 粗筛四项 token 指标**全部重叠且中位反向 +2.6～+4.5%**——
  inclusive 份额零墙钟转化（HYPOTHESIS：CFPreferences 进程内域缓存已摊薄
  物化成本；非 caller 份额的结论性推论）。勿重试该链的微优；等价前提
  钉死保留在 checkLocalizationResolutionChain（Darwin ICU 语义+
  CFPreferences/persistentDomain 一致性；Linux corelibs 忽略 preferences 恒
  返回首候选的 legacy 行为——注意 Linux 省略 locale 的调用**同样求值默认
  参数解析链**，声明在 #if 外，复核 F4）。该链**禁止事件失效缓存**
  （LocalizationChecks 直接写 UserDefaults 逐调用生效是行为钉死）。配套
  mini harness 数据点（操作员报告，HYPOTHESIS）：重定位 SwiftPM 二进制
  疑似含硬链接均 SIGKILL（原地规则的可能扩展）；
  check-localization-runtime.sh 不在 CI 组、mini 上不可执行
  （WORKSPACE-DESIGN.md:166），钉死载体用 WorkbenchCoreTests（CI 仅
  macOS core-regression 执法 Swift 钉死，Linux 分支本地验证）。
- **NarrativeTextCache 字节键（KB 指标下已测并否决——重试路径关闭）**
  （round 21，行使并终结 round-20 条目预留）：long-tail-stream 指标
  （唯一文本/更新、707→2,907B、MISS 保真）下 v2（withUTF8 修复版）Mac
  六轮扩展粗筛六项全负（-1.88～-3.50%）但全部重叠——真实效应 ~2-3.5%
  在噪声带内；Linux -5.5% 3/3 分离为 Linux-only 形态。画像表机制命名桶
  并集（去重、单一分母——复核 F2 口径）25.73%→7.96% of all（-17.77pp）
  → wall 仅 -3.5%：**内存层级敏感机制（字典探针/驱逐/大表）的画像份额
  不可线性迁移**（解释 HYPOTHESIS：bench 表 <150 条目 L1 常驻 vs 画像
  8,192 驱逐循环）。勿再以叙事文本表键机制立项；phase(from:) 为 narrative
  KB 段剩余最大单一机制（助手帧 60.82→75.07%/闭包 only 54.61→73.36%），
  但其可迁移收益未确立（复核 F4：短路负载非同构），立项以粗筛裁决。
- **归因 harness 同构性第三、四维：容器动力学与分支短路负载**（round 21，
  扩展 round-20 条目）：③ 画像循环的万次更新使有界缓存反复驱逐重建、桶探针
  脱离 L1——凡候选机制作用于**随时间增长的容器**，画像必须匹配采纳指标的
  容器规模与寿命，否则份额系统性高估（实证：表机制并集 -17.77pp → wall 仅
  -3.5%，解释为 HYPOTHESIS）；④ 画像文本的**关键词命中/短路位置**必须与
  bench 一致（round-21 画像第 7 谓词短路 vs bench 32 谓词全扫——评审方对
  10,000 条重构文本确认），否则分支密集机制的份额跨载不可比。
- **stdlib 字节访问热路径陷阱**（round 21 v1 实测；范围经复核 F1 精确化）：
  `String.UTF8View.elementsEqual`（及同族 Sequence 算法）走 IndexingIterator
  逐字节 `Collection.subscript` witness——实证 1,892 样本/11.08%，KB 文本上
  与 NFC 哈希同量级；`withContiguousStorageIfAvailable` 对非原生存储（实证例：
  桥接 NSString）返回 nil，对 substring-backed String 的 nil 频率**未归档
  实验、不作断言**（初版概括已撤回，ERRATA E1）。字节级操作一律用
  `String.withUTF8`（mutating——需局部 var COW 副本；任意存储给连续缓冲；
  round-21 v2 实证 ByteText 机制 24.30%→9.51%）。
- **粗筛均值回归**（round 21）：n=3 的 -9.5%（token2000_narrative，逐对
  3/3）在 n=6 回归至 -2.52%——临界/边缘分离候选必须扩展粗筛轮数再裁决，
  勿以单批小样本开正式轮。
- excerpt 的 `prefix(320)` 字素行走/物化开销：round 12 立项前的 Mac 粗筛（SwiftPM
  scratch 包，9×20,000 次交替、64 轮换输入、哈希消费防提升）否决——`prefix(320)`
  本就把全部下游 collapse 工作截到 ≤320 字符，超过 320 标量的文本要先付一次到
  321 标量才中止的带上限 collapse/count 扫描（仍覆盖大半文本）：v1 融合截断折叠
  +20.1%/+20.7%（CJK 337/368 标量 fixture），v2 先计数+就地折叠 +4.4%/+4.9%，
  longAscii +27.8%/+1.8%；仅 14 标量短文本 -37%。标量计数上界只能对 ≤320 标量
  证明 prefix==whole；这两类实现被否决不构成"不存在更便宜 sound 替代"的证明，
  但未找到可用替代。等价性设计本身可行（41,092 对差分 fuzz 零失败——注意语料
  覆盖的是融合原型变体，非被计时的 count-first 变体），是性能不成立；证据与
  更正见 round-12/prefix320-screening/（含 ERRATUM.md：单位实为 ms、归属更正、
  重跑验证日志）（round 12）。
- `SessionEditStats.tally` 的迭代器遍历换借用索引遍历（round 13）：Mac activity
  profile 的 `IndexingIterator.next()` 8.64% self 归因扎实，但替换后
  edit_stats@6400 仅 -1.65%（最差对正向、区间重叠），Linux 持平；同走 derive
  的 edit-lines 场景仅 bulk 越界（+12.07%，场景选择性 → 布局伪影嫌疑，按
  round-10 先例作回归信号处置）。教训：**归因的 self-time 占比不保证可
  转化**——优化器对索引访问的字段级加载消除可能已覆盖迭代器大部分机械
  成本；SessionEditStats 家族的机械微优候选立项前先做 Mac 一对目标场景
  粗筛（与绕 Foundation 类同规则）。勿单独重试 tally 遍历形态。
- collapsedWhitespace 字节路径的循环形态重写（去 Range 见证、ASCII 批量
  append、属性块表快速拒绝；round 15 粗筛）：三路差分等价全过（35 固定 +
  40,000 fuzz）但 Mac **+16.56% 更慢**（9/9 块一致 +10.5～+24.1%）。
  append(contentsOf:) 切片分派/ASCII 双遍/块表间接层的机制假设均为推断。
  勿重试该方向，除非有指令级新证据（round 15）。
- **孤立微基准两个方向都不可外推**（rounds 13+15 合并教训）：round 13 归因
  self-time 8.64% 未在上下文转化为收益；round 15 lineCount SWAR 孤立粗筛
  Mac -69%/Linux -21%，上下文内 Mac -39%（采纳）而 **Linux 回归 +27.78%
  （v1 二进制）/+31.1～+32.1%（v2 修正掩码二进制）**（定位表述经评审 B3
  更正：回归的普通非 bulk edit-lines 行走未改动的 fullLineDiff、属 round-8
  布局摆动家族（bulk 行走两计数快路径、确调 lineCount）；edit_stats 三档
  回归与上下文内 lineCount 聚合成本相容（~0.78µs/轮）——均为推断，机制
  未解）。机械类候选立项前必须在**双端 bench 模式内**（上下文内）
  粗筛；单端上下文回归需全量披露并按"Linux 筛选、Mac 仲裁"规则处置
  （round 15）。
- **搜索 haystack 的 UTF-16 物化（脚本依赖）**（round 16 粗筛#1）：把
  ConversationSearch 合并搜索文本物化为连续 UTF-16——等价全过但 **CJK 查询
  +13.5～+21.8% 更慢、ASCII 查询全变体 -3.9～-25.0% 更快（v1 -3.9/-7.2%、
  v2 -9.3/-11.4%、v3 -22.6/-25.0%）**：CF 对惰性桥接的 Swift
  原生字符串保有 UTF-8 直读快路径（_CFStringGetCStringPtrInternal），物化
  丢失之；产品代表查询为 CJK，且按查询条件物化会污染与查询无关的
  Entry.text 缓存。勿凭 ASCII 微基准立项、勿重试该方向（round 16）。
  对照：**检测器侧**物化（NSDataDetector 输入）方向相反——DD 逐字符
  character(at:) 桥接是纯开销，-34.8% 采纳（round 16 候选）。
- **手写字节扫描替换 stdlib 搜索时保留快速拒绝前缀**（round 17 v1 教训）：
  无条件标量字节扫描取代 `utf8.contains(92)`（stdlib 对无命中串走快速
  搜索路径）后，Linux 上不经过改动函数的指标出现均匀位移（+4～+6%）与
  温路径 +1 打印格；恢复 contains(92) 前置（逻辑等价：有对必有反斜杠）
  后全部消失。字节扫描的收益在**替代 grapheme 级搜索**，不在替代字节级
  快速拒绝。

## 候选队列（按当前证据排序）

依据 round-12 复剖（base=7d5ba26）与 round-15 三场景复剖（base=9c12eb9，
[归因](round-15/attr/)）重排：

1. **find-bar 冷首搜与每 delta 地板**：round-15 复剖澄清 streaming profile 的
   search 区域（52.1%）主体是**每轮首查询的全窗冷搜**（产品对应开查找栏输入
   首字符；bench 每轮新建 ConversationSearch），由 CF locale 匹配（语义红线）
   与 ReplyDocument 渲染构成——优化空间在渲染/缓存结构而非匹配语义；每 delta
   温路径地板（prefix memcmp、hits CoW 拼接、最近轮 `ConversationTimelineEntry.make`）
   涉及 `ConversationFindResult` API 形状的改动会波及 UI，红线内先评估。
   **round-16 后记**：NSDataDetector 桥接块（~26%）已采纳移除（Mac 冷首查
   -19.75%）；余量：ReplyDocument.parse ~14%（cmark+normalizeDelimiters；
   循环形态重写需指令级新证据——round-15 collapsedWhitespace 粗筛先例）、
   CF 查询匹配 ~5.7%（语义红线）、跨实例渲染缓存与 UI 实例生命周期
   （AgentWorkbench 红线内不可动；WorkbenchCore 内有界缓存需先过"不得
   引入全局 memo"的设计论证）。
   **round-17 后记**：normalizeDelimiters 守卫已采纳移除（Mac 冷首查再
   -8.27%、Linux -12.79%）；余量：NSDataDetector 内部（langid/DD 词法/
   trie——检测输出即行为契约，事实红线）、ReplyDocument.parse 的 cmark
   本体、splitInline 闭包 3.7%（**该计数已退役**——round-19 复核 F1：
   不可从归档 trace 复现的归属桶数字，改用 inclusive 口径 1,199/5.65%，
   重算脚本归档 round-19/attr/；$ 扫描 String.Index 机制——字节化需强
   钉死+双端粗筛）、CF 查询匹配红线域 7.6%。
   **round-19 后记**：splitInline 守卫已采纳移除（采纳数据 v2=1f9b5d4：
   Mac 冷首查 -5.93% 六对全分离、Linux 筛选 -9.54%；v1 -5.58% 迭代幅度
   一致）。归因引用一律用 inclusive 口径（闭包 1,199/5.65%、其叶方向
   contains 1,163/5.48% @21,222）；**"实测超归因/每字节成本更高"推断不
   成立已撤回**——样本份额与墙钟改善的比较不能建立每字节成本论断，任何
   此类机制解释仅为 HYPOTHESIS（round-19 复核 F1/F1'）。余量：
   NSDataDetector 内部（事实红线）、ReplyDocument.parse 的 cmark 本体
   （循环形态重写需指令级新证据——round-15 collapsedWhitespace 粗筛
   先例）、CF 查询匹配红线域。find-bar 冷首查的 WorkbenchCore 侧可动
   机械热点至此基本清空。
   **round-22 后记（phase 已采纳移除）**：phase 单遍字节扫描采纳数据
   v3=4b9ac95（Mac longtail_narrative **-87.37%**、token narrative
   -69.94%/-70.75%；Linux -73.13%；v1/v2 的 -87.27%/-86.99% 与
   -73.03%/-72.87% 为迭代历史值）。narrative 段剩余构成（round-21 v2 画像口径）：clean/
   narrativeText 派生（trim/collapsedWhitespace/range——collapsedWhitespace
   重写已在否定清单、trim 家族已在否定清单）+ String 键表机制（字节键
   方向已关闭——round-21 条目）+ 固定成本。presentation-token 场景余量
   转低。全局队列余量：cmark 本体/NSDataDetector 内部/CF 匹配（红线）、
   TimelineEntry.make（结构性散点）、collapsedWhitespace 7 标量契约缺口
   （正确性轮）、dashboard 归因（低优先）。
   **round-21 后记（KB 尾部指标已建，phase 为最大剩余机制）**：
   long-tail-stream 场景已入 bench（唯一文本/更新、MISS 保真、707→
   2,907B），未来轮次 A/B 电池自动携带 longtail200_* 指标。miss-heavy
   KB 画像：**phase(from:) 为 narrative KB 段最大单一机制**（助手帧
   inclusive 60.82%→75.07%；闭包 only 54.61%→73.36%——复核 F2 口径）
   ——lowercased() 全文拷贝 + 最多 **32** 个逐次 contains 子串搜索（复核
   F4 更正计数）；bench 长尾文本零关键词 ⇒ 32 谓词全扫，而画像基文本含
   "验证"第 7 谓词短路——**短路负载非同构，可迁移收益未确立，由粗筛
   裁决**（复核 F4）。round-22 候选方向：单遍字节级多模式匹配（ASCII
   关键词大小写不敏感字节扫描——0x24 型自同步论证适用、32 关键词无一含
   'k' 故 Kelvin 桥不适用；CJK 关键词字节精确；等价钉死=穷举标量桥接
   走查+关键词富集语料黄金，round-19 评审方 1,112,064 标量走查先例）。
   字节键文本表方向已关闭（见否定清单 round-21 条目）。
   **round-20 后记（presentation-token 已初探，结论限定——复核 F3）**：
   narrative 段（ActivityNarrativeProjection.make，占 token 更新 75～91%）
   两次归因：KB 级尾部（24～8,417B）下 NFC 规范化哈希 inclusive 50.01%
   （字节键候选 bench 不分离被否，KB 级墙钟收益**未测**非证伪）；短尾
   （≤262B）稳态循环**缓存热**画像下 L() 默认参数链 inclusive 56.71%
   （精化候选实测零转化被否）。短尾画像的缓存命中分布与 bench 首见
   MISS 不同构——**不宣称该场景低余量**；重选前需 miss 分布保真画像
   与/或 real-stream 族指标。五个 bench 族至此均有过归因（口径与限定见
   round-20 报告）。
2. **SessionEditStats 残余（小项）**：`lowercased()` 每 tool_use 分配（0.22%）。
   工具名 ASCII 大小写比较需先穷举非 ASCII 映射边界（round-22 的 U+212A
   穷举扫描机制可复用；32 关键词无 'k' 的论证形态适用）。
   **round-23 后记（fullLineDiff 字节区间化已采纳移除）**：行比较与
   Substring 物化侧已由 round-23 采纳（采纳数据 v2：Mac edit512 族
   -19.7～-20.8%）；`lines()` 本体仍供 patchStat/changeStat 使用（未动）；
   canonical 形态（全文 NFD 构造）为设计内权衡——v1 Linux 分离正向
   （+8.65%/+7.86%）**未在 v2 采纳字节复现**（双端带内；评审 F8：Edit
   API 不保证 old/new 同规范化、真实频率未测、47:1 仅合成语料比例）；
   若未来消除该权衡（如长度分布启发式），须以新假设单独立项并重走
   双端粗筛。
3. **小机械拷贝**：`TurnStatus.swift:89` 的 `Array(messages.dropFirst(start))`
   复制；`ConversationActivity.outputCharacters` 对每个 text/thinking 走
   `utf16.count`（可参照 `KimiInFlight` 的既有缓存口径，不得引入全局 memo）。
4. **TimelineEntry.make（cold 场景 12.1%，round-17 复剖，未动过）**：
   冷投影每轮合成时间线条目；先做叶帧级归因再定候选形态。
5. **Mac mini dashboard 归因（低优先）**：`--mode all`/`dashboard` 在 Mac mini 上
   确定性失败（Missing directory scroll view，mounted=False 但 projection_matches=
   True）；SSH 与 GUI runner 两种上下文同样失败，GitHub CI 同代码通过——本机环境
   因素（候选假设：acceptance app 的偏好域残留、macOS 27.0.1 行为差异、显示器
   状态）。不阻塞轮次；归因前先跑一次全新偏好域 + --mode dashboard 单独复现。
5. **collapsedWhitespace 7 标量契约缺口修复**：字节路径对 U+0E33/U+0EB3（泰/老
   Sara-Am 类）与 U+1F3FB–1F3FF（emoji 肤色修饰符）在空白邻接下返回快路径结果，
   而工具链实际把它们与前随空格融合成一个 Character，违反"等于 split/join"的文档
   契约（既有缺口，round 11 穷举走查已按现状钉住并特征化，两端同为 7 个；macOS
   另有 39 个 PUA 标量属安全反方向）。修复方向：为 `beginsBindingMark` 扩展钉死
   融合集，与 Prepend 集同一处理（过包含安全 + 穷举校验）。单独轮次立项。
6. **macOS 侧（等用户输入，可选加速项）**：真机切换会话 1.3–1.6s 卡顿归因需要
   用户日常使用中的诊断导出（perch-diagnostics.json）。合成 switching 基线已测：
   median 79–89ms，在产品目标内，无 20x 余量；冷启动 5/5 通过（时长指标待提取）。
   frames/hitch 校准为 2026-09-23 起已知未通过项。
