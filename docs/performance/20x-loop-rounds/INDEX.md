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
当前 base=15f612f。

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
| 16 | 2026-11-14 | 裸 URL 数据检测器改喂连续 UTF-16 存储输入（find-bar 冷首搜） | **候选（采纳 Mac 仲裁；待评审/CI）：Mac find_bar_cold_query -19.75%**（1625.95→1304.76ms，spread 1.66%，六对全分离，最差对 -18.87%，逐对 -305～-331ms 幅度一致）；Mac 全部 80 项指标零正向超 spread、温路径 find_bar_query_update 0.00%；Linux 侧 canImport(Darwin) 守卫构成**无变化护栏**（cold -0.15%、85 项零正向超 spread）；归因（新冷查询专剖：中位 1597ms@16k 消息窗、21,067 样本、按调用点归属）：linkMatches（NSDataDetector）~26%——_nativeGetIndex 的 98%、langid/DD 词法帧 100% 归其（检测器经 character(at:) 逐字符读惰性桥接 Swift 串）、ReplyDocument.parse ~14%、CF 查询匹配循环仅 ~5.7%（红线）——**round-15 曾把该 52% 区域整体归为 CF 语义红线，本轮据调用点级归因重画边界**；产品面：查找栏每次打开（@State 实例随栏销毁）+ 工作区历史搜索每键每会话（HistorySearchWorker 每查询新建实例）支付全窗冷搜；粗筛#1 haystack 物化**否决**（等价 PASS 但 CJK 查询 +13.5～+21.8% 更慢/ASCII -9～-25%——CF 对桥接 Swift 串有 UTF-8 直读快路径，脚本依赖，入否定清单）；粗筛#2 检测器输入物化通过（d1 -34.8%、156 组等价 PASS、__NSCFString 往返保真探针）；改动：ReplyDocument.linkMatches Darwin 分支单点（CFStringCreateWithCharacters 物化+空串直通；Linux regex 回退零改动；AgentWorkbench 零差异）；钉死：checkLinkScanContiguousUTF16——parse 输出规范化序列化 + 3,000 文本 fuzz 语料**按平台黄金摘要**（在未改产品上捕获：Mac 97e345c9/Linux 5dd61f86；两后端边缘形态合法分歧——Darwin 卷尾随 CJK 入 URL、粘连 "xhttps" 视为未知 scheme，Linux regex 均不）+ 结构固定例（跨 URL 的 $ 对保持字面、math/URL 共存、链接文本守恒）+ 确定性双跑；**Mac base==cand 同摘要 = 等价直接证明**；固定例初版编码粘连形态仅 Mac trap（exit 133@49 PASS，双侧探针取证后改 CJK 分隔形态，先于任何测量，日志归档）；检查两侧全绿无预期失败（Mac 各 98 PASS/Linux 各 97+1 SKIP）、portable 10/10（9e7bc19 dirty=false）；伪影如实披露：Linux 首次尝试因构建树先删 → checkRemoteSetup #filePath 探针 trap（harness 伪影、双侧一致、发生在新钉死通过后；修正后整侧从零重跑 ab2/）；Linux clean 重建字节不可复现（环境级构建非确定性、双侧一致出现；降级为源状态核验+六对哈希恒定+黄金摘要验证链）；新 bench 指标 find_bar_cold_query（StreamingBench 夹具改动两端同一、hash 在案；测量置于全部既有指标后不扰动）；汇总器统计定义先对 round-15 双 JSON 153 项指标自校验零失配 | [round-16](2026-11-14-round-16.md)；[数据](round-16/macos.json)；[归因](round-16/attr/)；[粗筛](round-16/screening/) |

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
  不要把 Mac 复测放到最后（round 10）。
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
  +13.5～+21.8% 更慢、ASCII 查询 -9～-25% 更快**：CF 对惰性桥接的 Swift
  原生字符串保有 UTF-8 直读快路径（_CFStringGetCStringPtrInternal），物化
  丢失之；产品代表查询为 CJK，且按查询条件物化会污染与查询无关的
  Entry.text 缓存。勿凭 ASCII 微基准立项、勿重试该方向（round 16）。
  对照：**检测器侧**物化（NSDataDetector 输入）方向相反——DD 逐字符
  character(at:) 桥接是纯开销，-34.8% 采纳（round 16 候选）。

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
2. **SessionEditStats 残余（小项）**：`lowercased()` 每 tool_use 分配（0.22%）；
   `lines()` 的 Substring 构建扫描（lineCount 已由 round 15 SWAR 化——Mac -39%
   采纳、Linux 上下文回归已披露；`lines()` 若仿此改造必须先双端上下文内粗筛，
   round-15 教训）。工具名 ASCII 大小写比较需先穷举非 ASCII 映射边界。
3. **小机械拷贝**：`TurnStatus.swift:89` 的 `Array(messages.dropFirst(start))`
   复制；`ConversationActivity.outputCharacters` 对每个 text/thinking 走
   `utf16.count`（可参照 `KimiInFlight` 的既有缓存口径，不得引入全局 memo）。
4. **Mac mini dashboard 归因（低优先）**：`--mode all`/`dashboard` 在 Mac mini 上
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
