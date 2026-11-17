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
当前 base=6ac65f9（round-37 评估轮合并）。

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

红线：不碰 Sources/AgentWorkbench（外观零变化）；**性能轮**行为断言变化
= 回滚；**事先明示立项的正确性轮以契约修复及充分 pin 为交付物，A/B 作为
无回归门槛**（round-24 口径，评审确认）；性能结论必须附交替 A/B 中位数
与噪声带。Linux 用于筛选；产品性能候选必须在
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
| 24 | 2026-11-15 | collapsedWhitespace 七标量契约缺口修复（正确性轮：beginsBindingMark 钉死融合集 U+0E33/U+0EB3/U+1F3FB–1F3FF） | **正确性轮交付成立/已合并（采纳数据 v2=c3d38a2，终 head d54c033；评审 5B+3NB 全部闭环——产品契约修复经评审独立重放确认零缺陷；merge=d8beb26）：七个标量（泰/老 Sara-Am U+0E33/U+0EB3 + emoji 肤色修饰符 U+1F3FB–1F3FF）被工具链 grapheme 分割与**前置空格**融合为一个 Character 且其 isWhitespace 为 true（strict 整簇丢弃），而属性查询（Grapheme_Extend/Mn/Mc/Me/ZWJ）全不报告⇒字节快路径曾保留标量，违反"等于 split/join"文档契约（round-11 走查特征化的 7 缺口、双端同 7）；穷举探针（**1,111,936 个非 ASCII 标量**——评审 F6 口径，walk 自 0x80 起；128 ASCII 由评审 384 例+本地自证补查零融合；Linux swiftc -O + macOS 解释器模式）双端确认缺口**恰 7 个**；过严方向（安全）Linux 31/macOS 70（**完整清单归档**，39 Apple PUA=U+F870–F89F 分项可逐条复算）；strict 语义双端一致；修复=钉死融合集命中即整串回落 strict，与 isPrependScalar/isNeverBindingScalar 同一契约（过包含安全、可领先数据绝不落后）；钉死升级：穷举走查从"特征化 7 缺口"改 **fusionGap==0 硬断言**（Unicode 漂移响亮失败）、detected 谓词镜像产品钉死集；16 结构例（前导/词中/多空格/词尾/单独+字母后/emoji 基后**快路径对照**）；专用 fast-path 模糊 500 条（既有混合语料含非 ASCII 空白恒走 strict 从不行使字节路径——新语料偶数半区仅快路径碎片**保证字节路径覆盖**；计数器 259/241 为**语料分类而非执行路由计数**——评审 F1：分类器查全串触发标量、产品只看空白邻接；评审源级路由重放 304 字节路径/196 strict、45 条误标；保证覆盖的论证经评审确认仍成立）；**行为变化=本轮交付物**（七标量空白邻接文本输出改为 strict 契约结果，如 `" ำx"` strict="x" vs 修复前="\u{0E33}x"）；**黄金摘要零移动**（narrative 语料不含七标量；评审复核既有测试 50 个肤色修饰符均有 emoji 基前驱）；**基线 trap 证据**（契约断言类钉死特有）：未修复产品必违反零缺口断言——双端基线侧 exit 133/132、**同一 MISMATCH 证据行**、trap 前 14 PASS、trap 位于结构例 precondition 而非走查（评审确认双端前 20 行相同）；记录不门槛；候选 checks 双端全绿（Mac 105/Linux 104+1）、走查 strict-path 双端恰 +7（2662→2669/2701→2708）、fuzz 分类双端逐项相同；**评审独立验证（产品零缺陷）**：原样产品对全部非 ASCII 标量直接对照 strict oracle——候选 **0 字节失配**、基线 7 失配；42,336 结构组合+127,008 存储构造检查+28 个非邻接快路径对照全过；**删除产品钉死集 U+1F3FC 的变异被原样 pin 捕获 exit 132**（镜像集不掩盖产品漏项）；120 份原始日志重算 183 项样本/统计字段与全部 headline 零失配；beginsBindingMark 不可被空白 run 绕过、foreign/non-contiguous 输入同入 withUTF8 body 无旁路；**无回归门槛（v2 正式六对，tests 对齐模板）**：Mac（仲裁）**90 项零超 spread 正向中位变化**（90 vs 88=两个全零打印格指标跨跑再现，round-22 88↔89 同型伪影；单对例外 6 处——retained_cost 族属 round-8 已登记"不要单凭它判退化"条目，余为边界性/打印格级）；Linux **95 项中仅 edit64_crlf +2.46% 6/6 正向分离**——SessionEditStats 源文件本轮 diff **零改动**（可证），布局效应机制为 HYPOTHESIS（F4 口径：源码未改不等同生成指令不变，未做指令级取证），量级远低于 round-8 登记带（±23~31%），round-23 v2 crlf 族 +3.84%/+2.18% 同签名前例，Mac 同族带内——按 round-15 先例全量披露不阻断；单对例外 11 处披露；**测量迭代 v1=172fd87 →（评审 5 BLOCKING 全部证据记录类：F1 计数器语义/F2 粗筛百分比舍入重算/F3 分类口径与噪声地板主张/F4 因果框架与 numstat（Tests +80/−15，107 系两文件总新增）/F5 porcelain 范围叙述（INDEX 不在脏清单）+3 非阻塞：F6 枚举范围与 Mac 全清单/F7 清单与红线措辞/F8 累计 diff 范围（1bcbc00..172fd87 共 7 文件含 round-23 settle 5 件；产品提交自身 2 文件））→ v2=c3d38a2（注释/输出行逐字更正，产品逻辑零改动）——按既定模板双端六对全量重跑，按机制免新复核轮**；全部更正自行重算验证吻合（粗筛值从未舍入 JSON 复算、分类复算、ASCII 补查复跑）；粗筛方法论（两条入否定清单）：v1 基线未带 tests 补丁⇒tests/product 字节双差异存在混杂**风险**（token2000_total 双端 3/3 信号 v2 与正式均未复现，因果归属保持 HYPOTHESIS）；同候选二进制（dc6b16db）n=3 四项逐对正向（三项区间分离、仅 longtail 两项中位超自身 spread）→ n=6 全部带内，但基线二进制跨批不同（f7dbea8c→354046d5）、候选自身跨批漂移 -4.68~-0.30%——**不足以确立通用噪声地板**（评审 F3 限定）；哈希首末一致（v2 Mac b80b427b/ff8e6552、Linux f13ede19/f88cc8c6）、Linux 候选 clean 重建**字节一致**（v1 dc6b16db/v2 f88cc8c6）、基线非确定性**第十二次（v1）/第十三次（v2）**披露（F7 收据+F11 路径清单协议生效）；v1 Linux edit512_unchanged -4.65% 6/6 负向=构建/运行噪声假说（正式双侧 Tests 字节相同不可归因 tests 差异；v2 +1.19% 带内未复现）；CI 89f2af0 与终 head d54c033 **各 15/15**（89f2af0 首跑 math parse_unclosed_4096 ratio 1.2777>1.25 失败——取证：候选 r2 轮 **8/8 场景最慢**早轮偏置+基线 ×1.70 离群、r6 回落基线常态、**调用路径零关联验证**（math 场景仅 ReplyDocument.parse/SwiftMath/ReplyMathImage，本轮改动函数仅经 collapsedWhitespace 到达、math 路径从不调用=死代码）；**静机真实门槛复测 passed**（Sources 有变故按 round-22 协议加做：BASELINE_REF=1bcbc00、typeset best_ratio 0.9933~1.0045、unclosed 检查项通过）；同 head 重跑全绿、门槛零改动、取证归档 round-24/ci/）；Codex 自动评审（d231162）**零发现**；红线：AgentWorkbench 零差异；行为断言变化=本轮交付物（正确性轮例外口径经评审确认入机制节）；未复活 round-15 字节循环重写方向；Mac 门槛 d54c033 通过（build 0+5/5+porcelain 0/0，v0.8.1-152；首次发送作业因模板 checkout 行未替换+清理冲突作废、重发前验证 worktree 干净后干净跑）、portable 10/10 @ d54c033（dirty=false）、mergeable CLEAN 后按零介入授权合并；**停止规则计数 1/3（评审确认——正确性轮契约修复非可采纳性能收益，不重置）** | [round-24](2026-11-15-round-24.md)；[数据](round-24/macos.json)；[探针](round-24/probe/)；[粗筛 v1 取证](round-24/screening-v1/)；[粗筛 v2](round-24/screening-v2/)；[v1 正式证据](round-24/ab/)；[v2 正式证据](round-24/ab-v2/)；[CI 取证](round-24/ci/)；[#346](https://github.com/chenweigao/perch/pull/346)，merge=d8beb26（01:32） |
| 25 | 2026-11-16 | 候选队列评估轮（机制探针+份额算术+bench 覆盖检查；未立项；评审更正后结论：队列尚未穷尽） | **评估轮/未立项/已合并（docs-only，产品树零改动；初版"队列穷尽/无候选"结论经评审 5 BLOCKING 更正撤回——队列尚未穷尽；merge=668ec61）；停止规则计数 2/3**（round-24 正确性轮 1/3+本轮；评审核对计数算术与 rounds 20/21/22 先例一致；round-26 优先候选=narrativeText 分隔符 range 搜索，非空洞轮）：**评审 F1（BLOCKING）撤回 utf16.count 普遍否决**——初版探针对同一组字符串重复预热（缓存热形态），四组比值实为 2.14/20.57/260/2.04（初版"2～20×"不符归档）；评审扩展探针（构造在计时外/结果消费/七对交替）冷字符串首次计数对照：2048 个新 JSONDecoder 4KB 串 stdlib 11.176064ms vs SWAR 3.091271ms（**SWAR 快 3.6154×**，操作员复跑 3.6026×、checksum 一致）、512 个新 CoW 追加流式尾部 **3.4240×**（复跑 3.4247×）；stdlib 同串二次计数较首次快 ~300×（11.18→0.034ms）="长 CJK 近免费"为热缓存伪影；ASCII O(1) 级快路径成立；**手写替代方向未关闭、不入否定清单**（否定清单改录"探针输入新鲜度同构"第五维教训），待 Mac 上下文内粗筛裁决；**F2（BLOCKING）缓存变体份额算术更正**：0.0344/0.7575=**4.541254%**（分母为 single_turn_activity@2000，初版误写 activity_init@2000）；该指标 Mac 历史 max_spread **3.940217%（r23v2）/4.295302%（r24v2）**、含 v1 为 3.94～7.50%——初版"4.6%<4.30~7.50%"不成立；夹具非同形（bench single_turn 为 1000 text 部件/19,890B，探针 2000 个/94,890B；同形补充探针 0.0101ms/窗）；Linux 分子可能高估 Mac 份额但不修复阈比较错误；缓存变体降级为**收益预期小暂不选题、未完成 Mac 裁决**；"不得全局 memo"不等于对局部状态所有者缓存的实质否决；**F3（BLOCKING）温路径地板降级为非实质否决**：0.28ms×10.714286%⇒≈30µs 为本批次换算非恒定地板（round-23 v2 温查询 0.285ms×3.571429%≈10.18µs）；round-21 的 ~4.1% ARC 份额属 **cold 投影区域**，`0.28×4.1%=11µs` 为场景分母错配、撤回；prefix memcmp/hits CoW 无独立归因属实但可省上限无证据——成本-收益暂不选题合法、非证据化否决，新归因证据可重开；**F4（BLOCKING）lowercased() 降级为低优先未选**：0.22% 出处为 round-12 归因键 edit_stats_region_top_leaves_percent_of_all=**全进程 self 叶份额**（画像 setup 62.1%），换算区域份额 ≈0.22/((1−0.621)×0.573)=**1.01%**（操作员复算 1.0130% 吻合），仍非 inclusive 可省上限；Mac 历史 spread 3.97～7.49%（初版 3.02% 系 Linux v1 值）——"低于噪声带 1～2 个数量级/数学上不可分离"撤回；**F5（BLOCKING）扫查遗漏三条剩余路径**：① **narrativeText 分隔符 range 搜索**（ActivityNarrative.swift:205-216 双 range(of:)、流式 progress 派生调用 483-490；round-22 后记明列 range 未入否定清单；token/longtail bench 现成覆盖；round-22 contains→字节扫描 -87% 同机制家族）——**round-26 优先候选，待归因与粗筛**；② patchStat/changeStat 分行路径（SessionEditStats:95-160、lines() 本体消费方、零 apply_patch bench 覆盖=未测缓议）；③ canonical 启发式重开条件保留开放未立项；"全部剩余项/唯一存活"表述撤回；F6（NB）TurnStatus 候选名=**TurnStatus.Progress.live(in:isRunning:)**、调用方 KimiWorkspaceView:455/NativeAgentView:141（非 ConversationActivityBar——其调用 TurnStatus.init）、诊断节引用第 7 项；F7（NB）跨实例缓存保真表述收窄（StreamingBench 前序查询已渲染窗口，缓存准入/容量允许时 **coldFind 第一项也可能不冷**；不预设首开墙钟必然不变；三前置门控合理非无故搁置）；F8（NB）docs-only≠零门槛噪声暴露面（四倍输入增长门无条件执行、语义检查保留——仅相对 A/B 性能门因 changed_inputs=False 不适用）；F9（NB）合成 switching 79～89ms 为历史 INDEX 引用值、本轮未复测、原始三轮工件路径待补，不据此认证当前体验；全部更正逐字执行并自行重算/复跑验证（扩展探针复跑 checksum 4557738/2529923 一致、F2/F4 算术复算吻合、F5 源码坐标核实）；产品树零改动⇒无字节移动⇒无需重跑测量、按机制免再轮；评审独立确认：docs-only 四处 diff 为空、原探针 0 失配/20,000 与四组量级复现、round-23/24 四份 JSON **368 项统计字段重算零失配**、portable 双提交（7a49a86/a347772）10/10 复跑、发布扫描 1766 文件 0 findings；CI：a347772 与终 head 47c9e5e **各 15/15 一次通过**（math changed_inputs=False 比率门不适用；F8 更正后表述：功能/语义/输入增长门仍执行）；portable 10/10 @ 7a49a86（dirty=false，工件归档）；mergeable CLEAN 后按零介入授权合并 | [round-25](2026-11-16-round-25.md)；[探针全套](round-25/probe/)；[#347](https://github.com/chenweigao/perch/pull/347)，merge=668ec61（03:09） |
| 26 | 2026-11-16 | narrativeText 分隔符搜索字节化（range(of: "："/": ") → NarrativeDelimiterScan 首次出现搜索：双侧 grapheme 边界证明 + 不可判定回落原谓词） | **采纳信号成立（Mac 仲裁；测量迭代 v1=77157a9 →（评审 6B+4NB 全部证据记录/表述类；产品实现经评审独立验证**零行为缺陷**：1,112,064 标量双向融合缺口均 0、规范桥/NFD 整对桥/隐藏匹配均 0、120,000 区间重放+1,440 长 detail+边界组合零失配、后边界删除变异体被结构例击杀 exit 132、120 份日志 89+95 指标与 2,208 样本 Double 严格相等重算、停止计数解释确认）→ v2=3e306a0（F7/F8 注释逐字更正，产品逻辑零改动，按先例双端六对全量重跑，**采纳数据锚定 v2；已合并 merge=ed98b97**：Mac **88 项零超 spread 正向中位变化**（v1 越带的 edit64_last/unicode 回带内 +3.38%/+1.18% 重叠）、分类器通过主指标三项 longtail200_narrative **-40.28%**（0.149594→0.089344ms，最差对 -37.15%）/longtail200_total **-36.51%**/token2000_narrative **-14.23%**，token200 族与 token2000_total 六对逐对中位差全负但中位在本批放大 spread（14.97/15.29/8.37%）带内=同向观察（F1/F9 口径；v1 批同族 spread 3.84/3.91% 时全通过，跨三批方向一致为负）；单对例外仅 4 处边界性；Linux v2 **95 项分类器 NONE**、主指标四项通过+两项 6/6 同向（-4.89～-15.73%）、Linux edit 族四项 6/6 逐对正向但中位带内（绝对 +2.0～16.3µs；Mac 同族带内/负向=跨平台不一致，round-8 布局家族，HYPOTHESIS 披露不阻断）；v2 哈希首末一致 Mac 6ead9f25/1caee0e1、Linux c2e8b283/84c3abd5，Linux 候选重建字节一致 84c3abd5、基线非确定性**第十五次**收据；checks v2 双侧 Mac 106/Linux 105+1）；待终 head CI/门槛/mergeable）：Mac longtail200_narrative -37.32% 六对全分离**（0.145906→0.091458ms，最差对 -35.65%、spread 7.68%）、longtail_total **-33.84%**、token200/2000_narrative **-13.45%/-13.83%**、token200/2000_total **-10.41%/-5.43%**——**六项主指标六对中位差均为负、按分类器（|change|>spread 且 worst<0）五项通过**（评审 F1 更正：token2000_total -5.429268360% < spread 6.505247770%，仅作同向观察不计入收益主张；逐对差值 longtail -51.1～-61.0µs）；Linux 筛选端同向全分离（-3.68～-14.86%，六项 6/6）；Mac 幅度大于 Linux（CFString 侧 grapheme 感知 range(of:) 较 corelibs 更贵——round-16/22 平台差同型）；选题=round-25 评审 F5 指认的扫查遗漏候选（ActivityNarrative.swift:205-216 双 range(of:)、流式 progress 派生每缓存 MISS 执行、token/longtail bench 现成覆盖、round-22 contains→字节扫描同机制家族）；**设计前提双平台穷举证明**：规范桥扫描（round-22 操作性机制，全 1,112,064 标量，Linux 编译+macOS 解释器）与 "："/":"/" " 规范相等的非自身标量**双端均 0** ⇒ 字节搜索规范完备；多标量不可合成原子（round-22 组合论证同型）；等价四层：① UTF-8 自同步（pattern 字节只落标量边界）无假位置；② **双侧边界证明**无假阳性——前侧仅 Prepend 可前向吸收（GB9b），ASCII 前邻/串首即证安全、非 ASCII 前邻查钉死 isPrependScalar；后侧查 **round-24 钉死完备的 beginsBindingMark**（fusionGap==0 走查背书，跨调用点复用——两谓词 private→模块内可见，无公开 API 变化）；③ 零规范桥 ⇒ 无假阴性（.absent 蕴含 range(of:) 亦无）；④ 不可判定 ⇒ 整体回落原 range(of:)（GB9b/融合角落平台分歧逐位保留）；首现同一性：首个确认字节出现=首个 grapheme 匹配，首个不可判定即整体交回；钉死 checkNarrativeDelimiterScan：**全管线差分**（公开投影面 headline/detail vs 改动前全管线逐字参考——必须含投影 pre-clean（483-486）与 appendStage 二次 clean（~530）两层：clean 对融合簇**非幂等**，首版 harness 漏两层致 5 处假失配（detail "**"→"" 等），产品扫描自始正确——harness 教训入档）；穷举规范桥扫描入钉死（零桥硬断言，Unicode 漂移响亮失败）；29 结构例（两分隔符全位置+Prepend 前邻+Extend/ZWJ/Sara-Am/肤色后随回落形态+emoji/CJK 确认形态+标记前缀+>48 headline+空侧）；2,000 seeded 模糊（唯一前缀表冷；语料分类计数 round-24 F1 口径——Linux 568/684/181/920/1080、Mac 503/649/159/865/1135，分类经平台 grapheme 规则故跨平台略异、阈值守卫双端过）双端零失配；分隔符字节 pattern 同步断言；**narrative 黄金 4e46d66eff016205 原样通过（语料含两分隔符=端到端等价证明）**；checks 全绿无预期失败（Mac 双侧各 106、Linux 双侧各 105+1——差分钉死基线侧按设计通过，与 round-24 契约断言类相反）；双端粗筛 3 对先行（tests 对齐模板+driver 6 位小数——round-24/25 教训内置）：Mac 主指标 5/6 项 3/3 分离（longtail_narrative -39.32%）、Linux 6/6 项 3/3 分离（-15.80%）；哈希首末恒定（Mac 2791a83a/2c43d0d1、Linux bc49c760/6a72cbeb）、Linux 候选 clean 重建**字节一致** 6a72cbeb、基线非确定性**第十四次**披露（收据含路径清单）；**edit64 族分离正向披露（双端成员不重合=布局家族关键证据）**：Mac edit64_last/unicode +3.23%/+3.23%（6/6，绝对 +2.9/+3.8µs）、Linux edit64_first/unchanged +1.97%/+3.00%（6/6，+2.0/+2.9µs）——SessionEditStats 本轮 diff **零改动**（可证）、edit-lines bench 仅调 derive（路径不含改动代码）；分离成员随平台漂移而代码同一=支持 round-8 登记布局敏感家族 HYPOTHESIS（round-23 v2 crlf 族/round-16 edit 族同型），**但不证明产品平台无测量回归**（评审 F2：主指标中位减少 3.906～54.448µs/model.update 与 edit64 中位增加 2.875/3.812µs/24-edit batch 单位不同不可相抵，短尾收益与信号显示值同为数 µs 级；round-15/16 免阻塞先例针对非发行 Linux 平台、不构成 Mac guard 自动豁免）；**处置=明示接受两项 Mac 非主指标测量回归的权衡后采纳**（评审判断：不单独增设自动否决门，但按真实测量权衡、不当成已证明的伪影消除）；归因保持 HYPOTHESIS 未做指令级取证；单对例外 Mac 17/Linux 17（Linux：13 处 edit 族 + chain_total P5 + cold@500 P3 + 两个 projection 例外**均为 P6**——评审 F5 更正初版 P6/P2 误写；Mac：14 处 edit 族 + presentation_update P3 + token2000_tool_projection P2 + page_model_total P6）F2' 披露；Mac 正式作业遗漏 fixture-hash 落盘（归档缺口如实记录：fixture 同一性由 git 状态证明——补丁不触 bench 文件+driver HEAD/porcelain 记录，Linux 侧清单在档、值与 round-23/24 一致）；护栏全带内（find_bar +0.35%、cold +0.29%、stage 0.00%、edit_stats +1.51%、round-23 领地 edit512 带内、append@2000 打印格 ±14.29% 第四轮同签名）；**停止规则计数归 0**（rounds 22/23/26 采纳；24 正确性轮/25 评估轮中断被重置——评审确认口径）；Mac 门槛 2880464 通过（build 0+5/5+porcelain 0/0，v0.8.1-164）、portable 10/10 @ 2880464（dirty=false）、终 head CI **15/15 一次通过**（2b9e730 首跑 math 噪声已按取证+静机复测+重跑化解）、mergeable CLEAN 后按零介入授权合并 | [round-26](2026-11-16-round-26.md)；[数据](round-26/macos.json)；[设计前提探针](round-26/probe/)；[粗筛](round-26/screening/)；[正式证据 v1](round-26/ab/)；[正式证据 v2](round-26/ab-v2/)；[CI 取证](round-26/ci/)；[#348](https://github.com/chenweigao/perch/pull/348)，merge=ed98b97（13:07） |
| 27 | 2026-11-16 | 跨实例 rendered-source 缓存（RenderedSourceCache：find-bar 重开/重复显式历史搜索付匹配+查表不付渲染；探针揭示第二机制=同遍重复 source 去重） | **采纳/已合并（Mac 仲裁；采纳数据 v5=a2ac5bb，终 head 8523e47，merge=b89851f（17:45）；三轮评审闭环、无未处置 BLOCKING）。测量迭代 v1=d191e9c →（归因探针：v1 bench“语义精确不变”注释错误——夹具模板串使 16k 窗口 18,216 个 source 出现塌缩为 963 唯一值（94.7134%，评审独立重放确认 produce=963/hit=17,253/7,550,375B=32MiB 的 22.5018709897995%），cold 收益主因=同遍去重（真实产品行为、夹具放大份额；跨实例 reopen 为独立机制）；探针二进制仅归因）→ v2=e6394ce（注释更正+钉死增强；六对一次锚定：Mac cold -43.58%、90 项 positives NONE；Linux -36.45%、edit 族 5 项分离披露）→ 独立评审（gpt-6.1-sol thinking:max）**3B+9NB**：F1 v2“重复 source”被 coalescingAdjacentAssistantParts 合并（重放 6 出现/6 唯一/0 重复，丢重复变异体存活、“x^2”查询 0 hits）、F2 机制钉死三变异体存活（reverse-lru/zero-accounting/admit-oversized）、F3“历史搜索每击键”与 UnifiedSearchView 实况不符（查询变化 cancelSearch）→ v3=28b3cb6 处置（产品逻辑零改动）：重复入独立消息 repeat-a0（7/6/1）、四制度全等含 **byteBudget-0 无缓存参考端**、精确断言（café 4 hits+entryID 精确顺序+occurrence 全 0+excerpt、display math $$x^2+1$$ 真实 latex 覆盖、行内 math U+FFFC 既有形状如实钉死零改动）、机制钉死补精确记账/具体 LRU/非空表超大哨兵/并发单份记账（Σ=570）/locale 世代真实通知主线钉死；**六变异体红跑全击杀 exit 132**（drop-duplicate 先被既有 paging 全等钉死、string-key 先被既有 round-12 洞探针击杀=纵深防御）；F3 措辞全清（AgentWorkbench 零改动）、F7 纯度论证收窄（static 只证构造一次、matches locale 独立=平台语义假设、ReplyMath 数学拆分准入关联）、F8 四处收窄（命中仍付键构造/哈希/锁/lastUse、precondition 非 oracle、“量级⇒布局噪声可忽略”降格风险限定）、F9 evictLocked 诚实成本（满表 churn 每插入锁内 O(N log N)，2,048B/9B/500 插入→273 次排序）、F10/F11/F12 数值逐字更正；v3 六对重跑：Mac cold **-43.61%**、reopen 147.735ms、89 项 positives NONE；Linux -36.32%、**95 项 positives NONE——v2 批 edit 族 5 项分离全部回带内**（round-26 v1→v2 同型，布局家族 HYPOTHESIS 强化）→ **复核评审（两 run 均未产出终版判定文本——如实披露，结论由操作方从其工作区 /tmp/perch-r27-recheck.36mF2N 脚本/收据/driver 日志逐件重建）**：确认 F1/F2 闭环（v3 重放 7/6/1、drop-duplicate 被 v3 钉死本体击杀 Pin.swift:227、budget-0 制度 produces=7/stored=0、机制补充八项全过、churn 273 复测）、v3 双端 60+60 日志重算 95+89 项指标 1,615 数值字段**零失配且官方 JSON 逐字节相同**、F10/F11 数值与组成（26+7+1）确认、f0c4cdd→v3 零逻辑差异、v3→afddf8f 编译输入零字节差；**新发现 N1（BLOCKING，v5=a2ac5bb 修复）**：v3 钉死/bench precondition 全部用 Swift String ==（规范等价）——复核独立 harness 证明 normalize-cache-hit-nfc 与 normalize-render-nfc 变异体（precomposedStringWithCanonicalMapping）**在 v3 独立钉死下存活**（proof：a1 oracle excerpt 100B NFD vs warm 99B NFC，canonical_equal=true/byte_equal=false）；v5 修复=四制度逐 hit **UTF-8 字节形状**比较（entryID/excerpt/occurrence/toolID/toolOccurrence）+excerpt 字面断言 Array(utf8)（a1 显式钉死 100B NFD）+bench reopen precondition 字节全等；**红跑双证**：全二进制两变异体 exit 132（先被既有 round-12 NFC/NFD 洞探针 SearchEntryReuseTests:363 击杀=纵深防御）、独立钉死 harness（复核同款方法、HEAD 断言）两变异体 exit -4/132 trap 于 v5 byteShape 断言（Pin.swift:244 回溯在档）、control exit 0；**N2（记录类，已修复）**：报告 3 处“每击键”残留逐字更正；round-27/ci/ 取证目录 afddf8f 漏提交已补齐；复核指认静机复测未覆盖 v3 产品字节（a7ef1771≠1d5c225d）——**CI @ afddf8f 15/15 一次通过（math 门在 v3 产品字节直接绿）关闭该缺口**；**v5 双端六对全量重跑（采纳批）**：Mac cold **-43.59%**（1129.97→637.41ms，worst -43.26%、spread 1.29%、六对全分离）分类器通过、reopen **146.635ms=候选内 -77.00%**、**88 项配对 positives NONE**（较 v2 少 2 项=state_reset/token2000_state_reset 打印格全零伪影 round-22/26 同型）、护栏全带内（query_update -3.45%/older_page -1.58%/chain 0.00%）、单对例外 5 处边界性、checks base 106/cand 107、哈希首末一致 522ea174/94245d43；Linux cold **-36.51%**（worst -36.06%、spread 0.78%）同向、reopen 228.97ms（候选内 -34.65%）、95 项中**唯一越带正向 longtail200_state_reset_ms +48.33%=纳秒级测量噪声**（中位绝对差 14.5ns；原始计时为整数纳秒时间戳——终版复核更正“打印格 5ns”表述，操作方复算 100 样本非整数者 0；产品逻辑原因排除、噪声归因保持 HYPOTHESIS=round-24 F4 口径；与 find-bar 零关联、Linux 筛选侧不承载采纳、Mac 采纳批无此信号，披露不阻断）、edit 族连续第二批不复现、单对例外 11 处（6 处 state_reset 自身+release_model_state P4=round-26 登记 ±14.29% 同签名+4 边界）、checks cand 106+1/base 105+1、哈希首末一致 2595493c/43fe2b72、候选 clean 重建字节一致、**环境级非确定性第十八例（基线侧）**；三批一致性：Mac cold -43.58/-43.61/**-43.59**%、reopen 147.15/147.735/**146.635**ms；Linux -36.45/-36.32/**-36.51**%；**方法论披露：基线=原始 ed98b97 树**（tests 引用新公开类型无法在基线编译，round-24 tests 对齐模板不可用；采纳只骑 350/1130ms 量级 cold——量级论证按 F8 为风险限定非受控结论；reopen 候选内单列，summarizer r27 唯一显式扩展 unpaired_single_side，配对统计经评审 AST 比较确认未变）；设计论证五点过“不得全局 memo”队列门（纯度限定版/字节精确键/32MiB 成本估计+批量 LRU+超大不入表+churn 诚实成本/locale 世代/produce 锁外并发良性）；注入=默认参数 .shared ⇒ **AgentWorkbench 零差异**（评审复核 72 文件产品仅 Search +12/−2+新缓存 166 行、AgentWorkbench 与 SessionEditStats diff=0、22 fixture hash 吻合）；CI @f0c4cdd 首跑 math 失败=round-24 同款 build-lottery 签名（candidate 内部一致 2.3%、baseline 同二进制跨轮摆 +37%、r6 末轮仍慢非早轮偏置、typeset-512 反向 0.98）+执行隔离（App.swift refs=0）→静机真实门槛复测 passed（typeset-32 ratio 1.0659/best 1.0339 全 <1.15、比率门 applied）→同 head 重跑 15/15 绿；**CI @ afddf8f 15/15 一次通过**；取证归档 round-27/ci/；Mac 门槛 @ afddf8f 通过（build 0+5/5+porcelain 0/0，v0.8.1-171）、portable 10/10 @ afddf8f（dirty=false）；**终版闭环复核（第三轮，run 止于中途小结无判定行——如实披露，工件 /tmp/perch-r27-final.uFpMAy/）**：v5 采纳批 120 份日志重算 183 项指标/3,111 数值字段零失配、官方摘要再生逐字节一致、单对例外 5/11 确认；**N1 闭环独立确认**（standalone HEAD pin @3e9c603 重放三种规范化注入形态全击杀 exit 132/-4、control 通过、repository unchanged）；两处表述更正（state_reset 整数纳秒时间戳、因果限定 HYPOTHESIS）逐字执行并自行重算验证、按机制免新复核轮；三轮累计无未处置 BLOCKING 遗留；**停止规则计数维持 0**（本轮采纳；评审 F12 确认算术）；Mac 门槛（build 0+冷启动 5/5+porcelain 0/0）与 portable 10/10（dirty=false）@3e9c603 与**终 head 8523e47**（v0.8.1-174）双跑通过；**CI @ afddf8f/3e9c603/8523e47 各 15/15 一次通过**、mergeable CLEAN 后按零介入授权合并 merge=b89851f | [round-27](2026-11-16-round-27.md)；[数据](round-27/macos.json)；[归因探针](round-27/probe/)；[粗筛 v1](round-27/screening/)；[正式证据 v2](round-27/ab/)；[正式证据 v3](round-27/ab-v3/)；[正式证据 v5](round-27/ab-v5/)；[变异体红跑](round-27/mutations/)；[CI 取证](round-27/ci/)；[#349](https://github.com/chenweigao/perch/pull/349) |
| 28 | 2026-11-16 | utf16.count 手写 SWAR 替代（ConversationActivity 五计数点；队列②门控的 Mac 上下文内粗筛裁决轮） | **不采纳/已合并（候选 ce901c0 → revert d30c9fa；merge=406b547（19:29）；终 head 47830e3 CI 15/15 一次通过、Codex 自动评审零发现、portable 10/10 @9087633 与 @47830e3、mergeable CLEAN；终树产品+测试与 main(b89851f) diff=0 行可证；停止规则计数 1/3）**：SWAR 恒等式（合法 UTF-8：units=非续字节数+4 字节前导数，8B/字）钉死完备——产品面 outputCharacters==stdlib oracle + **1,112,064 标量 × 9 对齐穷举** + 14 结构例 + 20,000 seeded fuzz 全字节精确，Linux checks 107+1、Mac 候选 108 PASS；**Mac 仲裁粗筛未建立达门槛的收益证据**：single_turn_activity@2000 中位 **-2.220680%**（0.715/0.726→0.692/0.717ms，逐对 -3.216783/-1.239669%，小于该指标**历史参考范围** 3.94~7.50%——历史 spread 系参考范围非已证恒定噪声地板），其余指标带内/打印格级；**Linux 定向粗筛两对同向不利**：同指标中位 **+5.703422%**（逐对 +4.693414/+6.722689，本批双侧 spread 0.916730/1.012292%、候选区间完全高于基线=批内分离），仅作增强止步的粗筛信号；activity edit-stats checksum 双侧逐位一致（54360/216360/1080360；**不含 outputCharacters**——评审 F5，其等价由钉死产品面 oracle 证明）；初版"探针份额算术吻合（4.5%×2.2×⇒+5%）"**撤回**——复用 round-25 已更正的混杂份额（同形探针份额 0.768061%、粗算 ~1.095057%），实测回归归因保持 HYPOTHESIS（评审 F2）；**Mac 未达采纳门槛 + Linux 不利信号增强 ⇒ 按队列②门控不采纳止步，方向②以 Mac 上下文内实证关闭；不声称已排除所有混合负载净收益**（评审 F1：双端方向相反不能排除 Mac 混合负载净收益，未测新鲜度分布、Linux 效应不可抵扣）（区别于 round-25 被撤回的初版热探针否决——本次为评审 F1 指定门控步骤的实测裁决；round-10 教训"Mac 粗筛不分离即止步"执行）；重开条件：未来产品路径以冷/新解码字符串**首次计数**为主且归因份额超目标场景噪声地板，仍需 Mac 粗筛先行（round-25 探针：冷首数 SWAR 3.42~3.60× 优势保留在档，不否定机制本身）；outputCharacters 缓存变体（F2 暂不选题）判定不受影响；**tests 未对齐披露（评审 F4，双端）**：pin 可在旧产品 API 编译（非 round-27 例外），两端粗筛均为定向筛选、不能独立确认因果，强因果主张需 tests 对齐复测；钉死两部分证明范围拆分（评审 F6：穷举走算法副本、产品面 oracle 经 ConversationActivity 公开断言，评审变异重放 87≠94 exit -4 独立验证接线）；归档补丁注释勘误入报告（不改写原始证据）；评审 F7 补档 Linux checks 原始日志+portable 收据；独立评审（thinking xhigh——注册表已无 max 档，如实披露）3B+5NB 全部证据/表述类（F1 结论收窄/F2 撤回份额解释/F3 表格拆行补对/F4 双端 tests 未对齐披露/F5 checksum 主张/F6 钉死范围拆分+勘误/F7 补档/F8 待合并措辞），逐字更正+操作方 6 位小数独立重算吻合，按机制免新复核轮；评审独立确认：SWAR 数学（458,752 相邻字节组合零失配）、历史 spread 四批重算一致、revert 完整（tree hash 级）、停止计数、docs-only 门槛先例（round-25 CI math 工件重放 changed_inputs=False、增长门仍执行）；伪影披露：首个 Mac 作业 checks 门后一行脚本 bug 中断（set -u 引用未赋值变量；checks 已过 exit 0/108 PASS），续跑复用同批二进制（哈希 24670f4a/ae0a36d6 首末一致）；产品树与 main 零差异（**编译输入相同**——不断言不同 revision 构建的 app 二进制字节必然相同，评审确认口径）⇒ math changed_inputs=False（比率门不适用，功能/语义/输入增长门仍执行——round-25 F8 口径）；docs-only 轮按先例不重跑 Mac 产品门槛（产品编译输入即 8523e47 已门槛状态） | [round-28](2026-11-16-round-28.md)；[粗筛](round-28/screen-linux/)；[Mac 裁决](round-28/screen-mac/) |
| 29 | 2026-11-16 | 归因刷新（post-round-27 双形态 Time Profiler）+ RenderedSourceCache 键批量字节哈希（Hasher.combine(bytes:)） | **采纳/已合并（Mac 仲裁；采纳数据 v1=d8b5f11 单版本无迭代；tests 对齐模板——`git diff 406b547 d8b5f11 -- Tests/`=0 行，双端 checks 同钉死集 Mac 双侧 107/Linux 双侧 106+1，无 round-27 式原始树不对称；merge=4f90b88（21:16），终 head 6e41793 CI 15/15 一次通过——中间 head 4cfb32c math 失败经取证为共享 runner 摆动家族（基线同二进制 draw_cpu +93% 摆动、四测量比率方向混合 0.92~1.15、执行隔离同 round-27）被 docs-only head 取代无需重跑；Mac 门槛 5/5（v0.8.1-186）+ portable 10/10 于 4cfb32c 与 6e41793 双 head 通过；Codex 自动评审零发现；mergeable CLEAN）：****评估段（归因刷新）**：双形态 xctrace @406b547（临时 bench 模式作业后还原 porcelain 0/0；自报中位 cold 631.9/reopen 143.9ms 与采纳批吻合=形态同构）——reopen 形态（21,033 样本）：**CF 查询匹配 45.63%**（__CFStringFoldCharacterClusterAtIndex 28.03%+CFStringFindWithOptionsAndLocale 17.60%，语义红线；检测器仅 ~1%=round-27 缓存生效）、utf16-bridge 10.12%（breadcrumbs/nativeCopy/nativeGetIndex，绑定公开 API 形状）、**cache-mgmt 9.82%（哈希叶 ~9.1%：Hasher._combine 3.87%+DYLD-STUB 2.98%+Array<UInt8>.hash(into:) 1.44%+getElement 0.80%）=本轮候选**、**display-serialize 14.37%（修正分类后的第二大块**——JSONValue.display 每遍每实例重建；初版误吸收进 setup-json 桶，评审以栈证据更正：JSONWriter.serializeString←display.getter←sources(of:)←hits←bench 测量段内；修正后 setup-json 仅 0.77% 真夹具）、sources-build（非序列化）3.92%、join-concat 仅 0.30%；cold 形态（20,544 样本）：cf-match 77.93% 内 **DataDetectors 内部 ~28.11%**（langid_consume_string 11.22%+DDScanner 4.71%+DDLexer 4.22%+computeLexems/UCharsTrie/DDTokenCache；round-17 后记事实红线：检测输出即行为契约）+CF 匹配 14.38%+胶水 ~11.8%、render（cmark 本体）仅 4.62%、cache-mgmt 3.98%（哈希 ~3.84%）、display-serialize 3.87%（修正分类）；**尺寸裁决一（DOA）NSDataDetector 字节预守卫**：临时探针（env 门控计数器，未提交已还原，绝不用于采纳数）——963 唯一 source（×7 实例=6,741 次 produce，22,056,587B）：简单守卫（无 http 且无点）跳过 26.58% 计数但仅 **3.653% 字节**；乐观 TLD 样式守卫代理（点后接 2-6 ASCII 字母）**3.688%**——".swift" 类扩展名即 TLD 形态几乎全放行；折算上界=cold 的 **1.8717%/1.8892%（约 1.87~1.90%；评审更正初版 ~1.6% 误算）**，处近期 spread 带（1.14~1.70%）上缘内外，但该值为"命中源全部字节×检测器全部时间可省"的**最有利上界**，未含闭源 DD 穷举证明负担（版本漂移/平台分歧）、检测输出即契约的事实红线（round-17 后记）、真实语料 URL/点占比更高的稀释、且仅 cold 单指标承载（reopen 对检测器 ~1% 不敏感）⇒ **仍不立项**（round-27 prep ASCII-successor 先例：算术先行不烧整轮）；bench 语料 http=0（无 URL）、dotOnly=4,949 如实记录；**尺寸裁决二（DOA）键 Array 分配消除**：memmove+malloc 叶合计 ~1-2%<noise ⇒ 只做哈希批量化；**候选（d8b5f11）**：SourceKey 等值保持**字节级 ==**（规范键禁令/NFC-NFD 区分/round-27 全套钉死含字节级制度断言不动），哈希改 `Hasher.combine(bytes:)` 连续缓冲整块执行替代 [UInt8] 逐元素；哈希**值**随函数变化、Dictionary 语义与等值契约不变；成本公式 key.bytes.count 数值不变；产品 diff 仅 RenderedSourceCache.swift 一文件（+20/−3）；**Mac 仲裁六对（tests 对齐）**：find_bar_cold_query **635.825→619.575ms=-2.56%**（精确 -2.5557%，worst -1.28%，spread 1.14%，六对全分离 -1.28~-3.31%）**分类器通过**；find_bar_reopen_query（本轮起为**配对**指标）**147.48→139.27ms=-5.57%**（精确 -5.5669%，worst -2.56%，spread 3.04%，六对全分离）**分类器通过**——归因预测吻合（哈希叶 9.1% of reopen，bulk hash 消除大半非全部）；**89 项配对 positives=NONE**（零越带回归）；护栏带内（query_update +1.79%/older_page -0.60%/chain +0.83%/longtail_narrative +3.19% spread 13.01%）；单对例外仅 3 处边界性（edit_stats@320 P3 12.33vs10.96、longtail200_turn_projection P1、token200_tool_projection P3）；checks **双侧各 107 PASS/0 SKIP**；porcelain 0/0；哈希首末一致 c0dbf4e5/9eb2a566；**Linux 六对**：cold **-7.69%**（350.085→323.175，worst -6.86%，spread 1.03%）、reopen **-6.77%**（229.25→213.735，worst -6.07%，spread 1.17%）同向且幅度更大（corelibs 逐字节 combine 相对更贵）；96 项中唯一越带正向 **edit512_unchanged +2.70%**（worst +3.85%、spread 2.33%、绝对 +16µs）——Linux edit 族布局家族同签名第 N 次：SessionEditStats 本轮 diff **零改动**（产品 diff 单文件可证）、Mac 同族带内/负向（edit512_first -1.19%/edit64_unchanged -1.11%）=跨平台不一致、round-8 带内（±23~31%）、round-23/24/26/27(v2 批) 同型、归因 HYPOTHESIS（round-24 F4 口径）、非发行平台——round-15 先例全量披露不阻断；负向越带 edit64_crlf -2.53% 同族反向摆动；单对例外 22 处（13 edit 族+cold@500/1000 各 2+projection 族边界）；checks 双侧各 106+1；哈希首末一致 89790711/d73e33ab、候选 clean 重建**字节一致**、**环境级非确定性第十九例（基线侧）**收据；**伪影披露**：Linux 作业脚本沿用模板时 out= 变量未更名，pair 日志落盘 .local/round27/ab29/（60 份齐全、driver 记录真实路径与哈希），发现后整体迁移 .local/round29/ab29/ 并修正脚本——数据未受影响（summarizer 对迁移后目录运行、哈希首末一致证明二进制未变）；队列余项重排（评估段产物+评审修正分类）：**display-serialize 跨实例缓存升级为队列首位候选**（reopen 14.37%/cold 3.87%，reopen 本轮起为配对指标可承载采纳；身份键设计与"不得全局 memo"门控论证为立项前提）；utf16-bridge 残余绑定公开 API 形状维持缓议；lowercased()/warm-path floor/TurnStatus dropFirst/patchStat/changeStat（零 bench 覆盖）状态不变；**独立评审（thinking xhigh；run 止于中途小结无判定行——同 round-27 复核型行为，如实披露，结论由工作区 /tmp/perch-r29-review.vgmZGm/ 五组审计工件重建）**：数据确认（两平台 120 份日志重算 96+89 项指标/3,145 数值字段零失配、Mac 两主指标分类器通过确认）；产品正确性确认（SourceKey 哈希契约 4,272 例/267 长度/16 偏移/1MiB/nil-0 缓冲/10,000 键 rehash 全 PASS、Dictionary 增长 rehash PASS exact cost=508,485、**round-27 全套变异体 against 本 head 重放全击杀 exit 132 含新增 normalize-excerpt-nfd**、original/supplement/full-original 全过）；尺寸探针复现逐位一致；两处实质更正（上界算术 1.87~1.90%、setup-json 混入测量段 display 序列化→修正分类重跑双形态）已逐字执行并自行重算验证、按机制免新复核轮；**停止规则计数归 0**（本轮采纳；round-28 不采纳的 1/3 被重置）；Mac 门槛 @4cfb32c 通过（build 0+冷启动 5/5+porcelain 0/0，v0.8.1-185）、portable 10/10 @4cfb32c（dirty=false）、Codex 自动评审零发现；待终 head CI/mergeable | [round-29](2026-11-16-round-29.md)；[数据](round-29/macos.json)；[归因](round-29/attr/)；[尺寸裁决](round-29/sizing/)；[正式证据](round-29/ab/) |
| 30 | 2026-11-16 | 跨实例已验证 entry 缓存（ConversationEntryCache：round-12 验证谓词跨实例化——重开/重搜付验证与拷贝，不付重建） | **采纳/已合并（Mac 仲裁；采纳数据 v5=ded7625；merge=a378a9c（01:36），终 head dcdf9df CI 15/15 一次通过（math 门在与 ded7625 相同产品字节上绿——两次共享 runner 失败 vs 静机复测 passed 完成噪声定性）、Mac 门槛 build 0+冷启动 5/5+porcelain 0/0（v0.8.1-196）、portable 10/10（dirty=false）、Codex P2 已修复并在 PR 内回复、mergeable CLEAN）：选题=round-29 修正归因 reopen 非红线最大块（display-serialize 14.37%+重建机制）；设计过"不得全局 memo"门五点（纯度=round-12 原谓词 sameSearchableWindow+sameQueryKey+options/running+收养；字节精确**单射**键；有界且**留存全计**；locale 世代+构建窗口守卫；单锁+验证/重建锁外+并发单份记账）；产品 2 文件，AgentWorkbench 零差异；**测量迭代五版**：v1=8732e11 →（独立评审 data-audit 确认 v1 数据零失配【96+90 指标/3,162 字段；Linux v1 例外组成更正 39 edit+6 cold+2】+两发现：键 0x00 分隔注释不成立【String 可内嵌 U+0000，"a\0b"+"c"≡"a"+"b\0c" 碰撞】、store 缺构建前世代捕获；评审 run 止于中途小结、结论由工件重建——同型行为披露）+Codex P2（键/query 字节不入账：1KB 预算 100×100KB 查询键全滞留账面 800B；PR 内已回复）→ v2=cf94157（长度前缀单射键+store(generation:)+admissionCost 留存全计+超大键拒绝）→（v2 九变异体电池：nul-collision/key-cost-exclusion/no-generation-guard 全被新钉死击杀，**canonical-string-key 存活**——长度前缀使 NFC/NFD 变长差异免疫规范碰撞、round-12 洞探针失守）→ v3=512c8ae（等长规范重排对 "a◌́◌̧"vs"a◌̧◌́" 键级断言）→（v3 电池**再存活**——断言打在 key() 字节层而变异体破坏表内 Key.== 层；e2e 重排查询零命中不可观测）→ v4=429d476（**字典级检索拒绝钉死**：orderA 键存→orderB 键取必须 nil）击杀 :104 →（**闭环复核**：v4 数据零失配【3,145 字段】+canonical-key 击杀独立复现+**两个 hook 证明**【世代捕获移位变异体死于补充检查:9、adapter sourceEnds 清空死于:25 ⇒ v2 守卫与适配层字段保真受击杀保护】+**新 BLOCKING：消息 JSONValue 载荷（input/output/source/metadata）未计入留存成本**——text 相位 entry 保留整条消息 content，~8MiB 滞留 vs 账面 77B@128B 预算）→ **v5=ded7625**（递归 jsonValueSize 计入 estimatedCost+手算全公式钉死+评审演示形状钉死【4,000 字工具输入→cost≥12,000⇒128B 预算拒绝】；修复规格=评审演示直接给出、成本口径不影响命中语义、按机制免再轮复核并完整披露；payload-fields-exclusion 变异体击杀 :223）；**教训入档：钉死必须打在变异体实际破坏的层**（键字节构造/表内等值语义/端到端行为三层；等长规范等价对是 NFC/NFD 变长对之外唯一区分字节等值与规范等值的查询形状）；**四代电池十形态全击杀**（收据 mutations{,-v2,-v3,-v4,-v5}/）；**v5 采纳批（双端六对）**：Mac find_bar_reopen_query **139.60→16.395ms=-88.26%**（worst -87.97%、spread 4.14%、六对全分离）分类器通过=主采纳指标；cold 616.77→629.10=**+2.00% 带内**（spread 2.01%，舍入 2.00<2.01；逐对 3 处单对越带披露）；**90 项配对 positives=NONE**；护栏带内（query_update +0.00%/older_page -1.33%/chain -1.67%）；单对例外 5（cold P1/P2/P4+retained_cost P5=round-8 条目+token200_total P6）；checks base 107/cand 108（0 SKIP）、porcelain 0/0、哈希首末一致 40578d5b/d5ac3d6c；Linux reopen **-78.08%**（213.18→46.735）同向、cold **+3.02% 分离**（store 成本五批一致 +2.90/+2.98*//+2.99/+3.34/+3.02%，*污染批旁证；非发行平台+Mac 采纳批带内=披露不阻断）；96 项 positives=仅 cold；edit 族连续第二批零中位分离；单对例外 10；checks 107+1/106+1、哈希首末一致 15a38c44/687d4dd5、候选重建字节一致、**环境级非确定性第二十一例（基线侧）**；**cold store 权衡处置（round-26 F2 先例明示接受）**：五批 Mac cold +3.36/+0.29/+1.42/+0.95/+2.00%（两分离三带内=带边缘）、Linux 五批一致分离=真实效应；首开一次性 +12.3ms（Mac v5 中位差）vs 每次重开 -123.2ms——第一次重开即回本；bench cold 每迭代新缓存=最坏形态非典型形态；**五批 reopen 一致**：Mac -88.62/-88.36/-88.12/-88.04/-88.26%、Linux -78.81/-78.03*/-77.95/-78.38/-78.08%；**方法论：基线=原始 4f90b88 树**（tests 引用新公开类型——round-27 同款披露；采纳骑 cold+reopen ms 量级配对指标，量级论证=风险限定 round-28 F8 口径）；bench 保真：既有指标注入双层新缓存（store 成本如实留 cold 内不美化）、reopen=默认双共享产品形态；**CI 事件取证（round-30/ci/）**：ded7cf1 双 GUI 失败=runner 抖动家族（失败检查零搜索引用、math 在 v1 字节通过；cf94157 15/15 一次绿）；512c8ae math 失败=**与 cf94157 绿 run candidate source_input 逐字节相同**（8d7cf1c5）⇒同 head 重跑绿；ded7625 双失败=navigation-disclosure GUI 高度断言（iteration 0、同作业其余六项全过、披露路径零搜索关联）+math 候选 r2 单轮尖峰（2.2-2.9ms vs 自身 r1/r3 1.1-1.3ms、中位比率反候选快 0.80-0.88）⇒**静机真实门槛复测 passed**（typeset-32 ratio 0.9479/best 1.0061、128 0.9923/0.9989、512 1.0005/1.0004，比率门 applied、candidate hash 与失败 run 一致 c5c03c8b）+同 head 重跑；门槛零改动；**操作事故披露（操作员自纠）**：v2 Linux 批计时段与前台构建并发（链完成误判）⇒污染批仅旁证、采纳批全新重跑；教训=链完成判定只看本链 driver DONE 行；**停止规则计数维持 0**（本轮采纳） | [round-30](2026-11-16-round-30.md)；[数据](round-30/macos.json)；[变异体红跑](round-30/mutations/)；[正式证据 v5](round-30/ab-v5/)；[CI 取证](round-30/ci/) |
| 31 | 2026-11-17 | 归因刷新评估轮（post-round-30 双形态 Time Profiler 构成图 + round-32 候选设计；未立项） | **评估轮/未立项/已合并（merge 5eb726a，PR #353，终 head 89d80c5；docs-only：`git diff a378a9c HEAD -- Sources/ Tests/`=0 行；停止规则计数 1/3）**：归因作业 @a378a9c（PerfRunner Aqua、临时双模式 harness 作业后还原 porcelain 0/0、自报中位 cold 605.4ms/reopen 15.69ms 与采纳批同形态；xctrace 40s×2；round-29 analyzer 扩展 verify 区域+ConversationEntryCache 模式+display-serialize 沿 round-29 修正分类）——**cold 构成（20,638 样本）**：cf-match **79.00%**（DD 内部：langid_consume_string 11.18%+FoldCharacterCluster 8.36%+Find/locale+DDScanner/DDLexer/computeLexems/UCharsTrie；+CF 查询匹配）=双红线（round-17 后记检测输出即契约+匹配语义红线）、utf16-bridge 4.64%、render（cmark）4.19%、display-serialize 4.15%、cache-mgmt 2.78%、其余碎片 ⇒ **cold 无候选**（非红线余量 ~15% 碎片化、单项 ≤4.6% 贴近噪声带；检测器字节守卫 round-29 已尺寸 DOA）；**reopen 构成（20,942 样本）**：cache-mgmt **18.97%**（dict find 6.60%+combine(bytes:) 1.61%+ARC）、timeline-make **18.24%**（每 hits() 重建 ~9k entries）、sources-build 区域 15.31%（**栈级复核：35.3% 含 verify 帧、仅 0.2% 真实 sources(of: 帧**——实为 verify 内务+KimiPart/ARC 拷贝；display-serialize 0.35% 独立佐证真实源重建≈零=round-30 缓存生效）、search-mgmt **13.62%**（实例 Entry 字典 9k 插入+键哈希+hits 拼接）、teardown **11.45%**、verify 7.65%+window-identity 1.05%、role-derivation **5.15%**（在缓存查询之前执行）、cf-match 仅 2.50%（**评审更正：时间拆分 515/523 在预热段（fixture 解码+计时外预热搜索），稳态（t>1.74s）仅 8 样本=0.04% 且叶子全为 NSString retain/release ARC——尾部轮匹配≈零才是 round-30 生效证明；稳态重算 cache-mgmt 19.77%/timeline 19.07%/sources-build 15.98% 强化主判定**）⇒ **剩余成本几乎全部为每实例结构开销，前缀级跨实例复用可绕过 ~85-90%**；**round-32 候选设计定稿：跨实例前缀（Earlier）缓存**——复用谓词=round-12 Earlier 同契约（sameQueryKey+options+sameSearchableWindow，命中免时间线合成/逐 entry 查表验证/实例字典构建）；键=query 字节+options 位（长度前缀单射，round-30 v2 模式，前缀身份由验证把关不进键）；留存全计（prefix messages+hits+entries 字典，text NSString 共享引用与 entry 缓存双重计数=保守超估披露；预算 64→128MiB 量级 A/B 后定）；locale 世代+构建窗口守卫（round-30 v2 契约）；单锁验证/重建锁外并发单份；集成=hits() 前缀分支三级（实例 earlier→共享前缀→逐 entry+store）；**流式语义保全**：同实例更新走实例层零变化、轮边界由收养 entries 字典供 previous 无回归；bench 保真=query_update/cold 注入新 PrefixCache、reopen 默认共享；**尺寸预估**（份额上界依据非承诺）：reopen 15.69→~2-3ms（-80% 量级；剩余=窗口验证 bitwise O(1)/值层 ~3MB 比较+hits 拷贝+尾部轮）、cold +store 走查 <+0.5% 如实计权衡、reopen/cold 均配对可分离性充分；钉死计划=round-27/30 全套移植（机制+四制度字节级 e2e+staleness 矩阵【前缀编辑/查询/options/轮边界】+变异电池）；风险=entries 跨实例生命周期/双重计数保守性/预算内存披露/双缓存世代一致性；**作业伪影链全披露**：①r31 首跑同名 job 发货竞态——runner 消费未修复版（cold 循环 entryCache 泄漏共享）⇒ 双 XML 均温形态（DD 帧仅目录级、两文件区域几乎相同；本地 Linux 复现修复版 harness cold 338.4/reopen 46.75ms 正确分离佐证诊断；XML 行级复核 bench 帧在场排除 checks 误录）——首跑 XML 保留为伪影不作 cold 归因；②r31b sed 遗漏无斜杠 mkdir ⇒ export "File does not exist"、**set -e 在还原段前中止 ⇒ mini 树遗留补丁**（计时段有效 cold 615.2/reopen 15.86 形态确认）；③r31c 脏树重复补丁 ⇒ benchR31Profile 重复声明 build fail（porcelain_before=2 为证；远程 checkout 复位）；④r31d 加预清理+真实 record 退出码捕获+export 容错 ⇒ 干净产出。**教训入档：PerfRunner 作业必须自防御脏树（预清理）；同名 job 不得在消费窗口内重发（换名）；管道后 $? 非目标命令退出码**；队列重排：①跨实例前缀缓存（设计定稿，round-32 优先）②cold 红线封闭 ③role 重排被①涵盖不单独立项 ④旧余项状态不变（lowercased/warm-path floor/TurnStatus/patchStat/changeStat/canonical/dashboard/切换诊断）；XML 按 round-15 先例留机不入库（mini <worktree>/.local/round31d/ 与开发机 .local/round31/xml-d/）；docs-only 轮门槛按 round-25/28 先例=portable+CI（math changed_inputs=False 比率门不适用、功能/语义/增长门仍执行），免 Mac 产品门槛（产品编译输入=a378a9c 已门槛状态）；**评审处置（第五次无 verdict 行中间摘要，工作区产物重建披露）：两发现均确认并逐字更正——①cf-match 解读错误（开发机自 XML 独立重算 515/523≤2s 一致）②首跑温形态归因文件错标（内容实为 r31c 异常栈；已自保留首跑 XML 重生成、异常栈按真名另存）；评审复算全区域份额零失配、sources-build 栈级复核一致（1,134/35.37%+6/0.19%）、r31 中位 vs 采纳批同形态（cold -3.77%/reopen -4.29%）、首跑伪影机制 unfixed/fixed 双循环重放确认；round-32 契约 replay PASS（faithful-prefix-lift byte-shape 605 项+NFC/NFD 收养契约）+切片留存边界（prefix 切片 suffix_retained=true ⇒ 必须物化独立 Array）并入设计 §3；记录级更正免新复核轮，停止计数 1/3 不变**；**CI**：761ff5f 首跑 15/15 绿；89d80c5 attempt-1 math 增长门失败（"Fourfold unclosed input grew too quickly"，contracts variant 本身 passed，interaction 聚合仅 MATH_RESULT 连带）——**决定性同输入证据：与前一全绿 run source_input_sha256（c5c03c8b…）与 baseline binary hash（017cdc4e…）双双一致，docs-only 不可能改变门输入；同 hash 另有 round-30 静机重测与终 head 双绿收据 ⇒ 环境非确定性第 22 例（首例双 hash 一致）**，同 head 重跑 attempt-2 15/15 绿；portable 10/10 @761ff5f；Codex zero findings；Mac 产品门槛豁免（docs-only，round-25/28 先例） | [round-31](2026-11-17-round-31.md)；[归因](round-31/attr/)；[作业伪影](round-31/artifacts/)；[CI 取证](round-31/ci/)；[portable](round-31/portable-results-761ff5f.json) |
| 32 | 2026-11-17 | 跨实例前缀（Earlier）缓存（ConversationPrefixCache：round-12 前缀级复用跨实例提升——reopen 只付一次窗口验证+不可变节点引用收养，跳过时间线合成/逐 entry 查表验证/实例字典构建与析构） | **采纳/已合并（merge=4c184e5，PR #354，终 head 904b94c；Mac 仲裁；采纳数据 v3=ec3111e；测量迭代 v1=c38e85f→v2=d19529f→v3=ec3111e；基线=5eb726a 产品树 a378a9c）**：find_bar_reopen_query **16.325→0.100ms=-99.39%**（六对全分离 worst -99.34%；spread 10.00 为 0.10/0.11ms 打印量化伪影、分离度为其 ~10 倍）=**全循环迄今最大单轮收益**；**90 项配对 positives=NONE**（cold +1.05% 带内 spread 1.65=store 走查每窗口-查询一次性；Linux 三批一致 +3.1~3.9% 分离披露不阻断——round-26 F2 权衡：首开一次性 vs 每次重开 -99.4%，第一次重开即回本；bench cold 每迭代注入新前缀缓存=最坏形态注记）；Linux reopen -99.63% 同向、96 项 positives 仅 cold；护栏 query_update +0.00%/chain_total +0.00%/older_page 带内；三批 reopen 一致（Mac -99.38~-99.39/Linux -99.63~-99.66%）。**三次评审驱动迭代**：v2=entry-ID 字典键计入（round-30 v5 教训前置应用）；v3=完成评审（第七次无 verdict 行，38 件工作区产物重建结论）闭环四类留存缺口——fileId 字节/sourceEnds 元素存储/message-part-hit-source 结构存储（前三类**继承自 round-30 公式**，双缓存约定一并补全，MemoryLayout stride 计价、count×stride 下界约定披露）+query 存储规范化（推进链独立解码等值 query 单缓冲指针钉死；sameQueryKey 门保证字节等同=行为中性）+**哨兵机制钉死**（评审两个 perf-only 存活变异体 bypass-shared-hit/drop-converted-entry 收口击杀：共享节点必须被 hits() 消费、.shared 转换必须供给同实例轮推进）。**变异电池 v3 17/17 全击杀**（v2 十杀+count-guard-only 等价变异体判定【sameSearchableWindow 双层内含 count 检查、外层守卫为纯快路径】+canonical-key 建模修正【hash+== 双规范化被杀，v2 只改 == 系桶分离建模不足】）；skip-verification 死于 SearchEntryReuseTests:120=round-12 既有钉死双杀。钉死：前缀表字典级重排检索拒绝、三路验证门（同数编辑/NFD 重建/count 变化）、===引用收养、**独立展开手算全公式**（评审：委托断言抓不到被委托方缺口）、REVIEW 三形状拒绝（fileId 窗口/2000 空部件窗口/4096 offsets）、替换记账、budget-0 oracle、LRU、超大节点+键、双重 JSONValue 留存（24KB 拒绝）、世代竞态、locale、removeAll、8×100 并发单份、四制度三层 budget-0 字节级全等×8 查询、共享温非空转、staleness 矩阵（前缀编辑/options/running/轮边界跨实例+d2 同实例推进 over .shared）；round-30 助手扩展三层 budget-0（oracle 语义保全）。bench 保真：cold/query_update 注入全新 PrefixCache、reopen 默认共享三层=产品形态。checks：Linux cand 108+1 SKIP/base 107+1 SKIP、Mac cand 109/base 108 全 exit 0；portable 10/10 @ec3111e（dirty=报告草稿 untracked 披露）。**CI**：6d11ec9 portable worker 'ready' 超时 flake（后续 head 绿）；d19529f attempt-1 host-workspace GUI flake（TaskContextReadingChecks:61 滚动 precondition、0 搜索引用、c38e85f 同检查绿、attempt-2 15/15 绿=**第 25 例**）；ec3111e attempt-1 math 门 "Typeset/draw regression exceeds 15% at 32"（取证：baseline 首轮预热尖峰 2.001ms vs 其后 1.350/1.195、candidate 1.33-1.73、中位比 +12% 低于门限、组合统计量被噪声早期轮推越；v3 差异不在 math 路径）——**静机重测 passed（typeset-32 ratio 0.9611/best 1.0129）+同 head attempt-2 15/15 绿（同 source hash 22ae55e2 失败/通过并存=第 27 例）**；环境非确定性第 23/24/26 例=Linux 三批基线重建字节不一致（候选三批均字节一致）。Codex：6d11ec9 zero findings。评审：kimi-code gpt-6.1-sol xhigh 两运行（第六次 4 分钟无产物即断；第七次 38 件产物无 verdict 行——变异/探针/审计/插桩全量留档，结论按惯例自产物重建并全部采纳；第一次运行三项确认【验证谓词/查询顺序/AgentWorkbench diff 零】计入覆盖）。**停止规则计数归 0** | [round-32](2026-11-17-round-32.md)；[A/B](round-32/ab/)；[变异](round-32/mutations/)；[评审产物](round-32/review/)；[CI 取证](round-32/ci/)；[portable](round-32/portable-results-ec3111e.json)；[#354](https://github.com/chenweigao/perch/pull/354)，merge=4c184e5 |
| 33 | 2026-11-17 | 归因刷新（post-round-32 双形态）+ 空后缀拼接守卫（reopen/query_update 脱离 18k hits 数组 COW 全量拷贝） | **采纳/已合并（merge=146d4fd，PR #355，终 head 44ada54；Mac 仲裁；采纳数据 v4=69094ed 等精度批；测量迭代 v1=afd99aa→v2=cb4d4a1→v3=2f64060→v4=69094ed，产品字节自 v1 未变=守卫一处；基线=4c184e5）**：归因半区——r31d 教训全套单次干净作业（porcelain 0/0/0、双 record/export exit 0、自报中位 cold 620.7/reopen 0.099ms 与采纳批一致；本地 harness 干跑预验证后发货）；analyzer 扩展（store-walk/prefix-cache/prefix-verify/hits-copy 区域+rule A/A2/B）：**reopen 稳态（t>2s，n=18,957，≈99µs）**=prefix-verify 26.9%（整窗逐消息字节比较本体 ~1.18MB≈27µs；**双平台直接探针 bitwise=true**——v1 初稿"padding 击败 bitwise"论经评审 F3 实测撤回，叶符号闭包归属 release 内联未决如实标注）、teardown 17.9%、**hits-copy 13.2%+search-mgmt 12.8%（bridge retain）=空后缀 `hits += []` 的 COW 全量物化及其销毁**（实证：空追加对共享数组仍拷贝，1M 元素 2.4-6.5ms）、后缀 per-entry 路径 ~20%、节点查表 0.6%；**cold 红线封闭依旧**（cf-match 78.5%、store-walk 仅 0.61%）。候选半区——`if !suffixHits.isEmpty { hits += suffixHits }` 单处守卫（值语义由 COW 保全；产品常见形态=查询只命中历史而 live turn 无匹配，流式重搜每更新/重开每次受益）；**Mac v4 等精度批（双侧 4 位打印，基线侧 print-patch 收据披露）**：reopen **0.0990→0.0774ms=-21.91%**（worst -16.10%，spread 11.13 基线真实离散首次可见，六对全负）+ **query_update -13.79% 分离** + cold +0.71% 带内（四批中性）+ **90 项 positives=NONE**；Linux 四批 reopen 全负（v4 等精度 -14.36% 带内=基线单侧离群 0.1945 主导 spread，如实记录筛选侧不承载采纳；v1 -23.91% 分离）、query_update 四批全分离、v4 96 项 NONE；**reopen 两轮累计 16.325→0.0774ms=-99.53%**。评审（第八次中间摘要结束但**首份正式 verdict 产物留档** review-findings.json=BLOCKING×3+NONBLOCKING×1，全部处置）：**F1（P1）混合打印精度分类器不健全**（见证 [0.0951×5,0.1149] 与打印一致而 |change|<spread）⇒撤回量化论断+v4 双侧等精度重仲裁；**F2（P2）钉死仅 running=false 重建路**⇒v2 三路+v4 **五路存储同一性**（重建/共享收养/running:true 收养/实例 earlier 双 running/推体重建）+投毒隔离+running-bypass 入电池（存活 v1 全部 108 checks、死于 v2+ 钉死 :589）；**F3（P2）padding/值层断言证据不成立**⇒两版断言撤回（v1 padding 论+v3 符号伪差论），保留实证（双平台探针 bitwise=true、26.9%=字节比较本体）；**N1** analyzer rule A2（array-destroy ARC 叶归 teardown，稳态 cf-match≈0 恢复 matching-only 诚实）。评审 verified：8,392 项差分字节形状+投毒隔离全过（vs 4c184e5 基线搜索类改名副本）、A/B 审计 120 日志/3,162 数值零失配、四路同一性双 running PASS、稳态阈值 t>2/3/5/10s 稳定。变异电池：v1 2/2 击杀+**v3 3/3**（remove-concat-guard :579/always-skip-concat StepAwareReadingTests:142/running-bypass :589）+**v4 复验 3/3**（:578/:142/:588，五路钉死版）+双 control 全绿。edit 族布局伪影三批闭环（v2/v3 8 项正向越带→v4 消失且反向摆动；v2/v3 候选二进制字节一致 81fb4c77=注释零 codegen 实证；v1 全带内；Mac 全带内；round-13 同族）。checks：Linux cand 108+1/base 107-108+1、Mac 双侧 109 全 exit 0；portable 10/10 @2f64060+@69094ed。CI：afd99aa bridge portable-worker flake（同签名第二例，attempt-2 绿）；2f64060 core connections settle 5s 超时 flake（NativeSubagentChecks:397 零搜索引用、mini 三批 109 PASS×3，attempt-2 15/15 绿=第 31 例）；环境非确定性第 28/29/30/32 例=Linux 四批基线重建字节不一致（候选四批均字节一致；#31=CI core flake）。Codex：zero findings（6d11ec9）。**停止规则计数维持 0** | [round-33](2026-11-17-round-33.md)；[A/B](round-33/ab/)；[归因](round-33/attr/)；[变异](round-33/mutations/)；[评审产物](round-33/review/)；[CI 取证](round-33/ci/)；[portable](round-33/portable-results-69094ed.json)；[#355](https://github.com/chenweigao/perch/pull/355)，merge=146d4fd |
| 34 | 2026-11-17 | 归因刷新评估轮（分页 older_page 三件套 + 流式更新链路双形态 Time Profiler 构成图；round-35 候选方向草图；未立项） | **评估轮/未立项/已合并（merge=529d41e，PR #356，终 head af28773；docs+归因轮：`git diff 146d4fd HEAD -- Sources/ Tests/`=0 行；停止规则计数 1/3）**：归因作业 @146d4fd（PerfRunner Aqua、r31 安全模板全套、**连续第二轮单次干净发货**：porcelain 0/0/0、双 record/export exit 0；本地干跑保真调试先行——初版分页 harness 因缺 bench 的 -5..<0 distinct-id 历史页池致 prepend 78ms=bench 11ms 的 7 倍膨胀，修复后 9.06ms≈bench ✓；流式 harness chain 2.055ms≈bench 1.83ms ✓；页池扩至 20 页/周期+窗口 16k→18k 增长漂移披露；自报中位行未被作业 grep 捕获披露）；相位切分（warm=JSON/apply 帧、prepend=presented/activity 帧、'.' 样本 next-marker 前瞻）：prepend 相 87.5%（17,861/20,409）。**分页 prepend 构成**：arc-copy 18.22%+string-hash 17.54%（combine(bytes:) 8.02%）+utf16-bridge 16.28%+string-compare 9.35%+dict-find 9.22%+teardown 7.82%——**字典机械≈36%+其 ARC/桥接=主体**；消费者归因：History.joined 5.20%+History.init 2.67%+ToolVisibility.projectTurns 5.09%+Pass.* ~1%；narrative 3.94（incl 7.4）/timeline-make 3.80（incl 13.1）/input-compare 2.28%/cf-match 0.82%（分页无查询近零✓）。**结构根因（评审 F1 BLOCKING 更正后，双侧源码核对）**：初稿"序号平移⇒memo 失效⇒全 turn 重拼"**撤回**——turn 粒度复用已存在且生效（HistoryTurn 按首条消息 ID+chunk 引用同一性复用、presented memo 仅键于 activity+foldsProcess 与位置无关、projectTurns chunk 按内容验证复用+位置无关锚点；剖面佐证 timeline-make inclusive 仅 4.16%=仅页边界 turn 重投影）；**每次 prepend 重建的是全局索引与容器层**：projectTurns 的 owner/turnAnchors/prefixIdentities（~16k identity 哈希插入，incl 18.24%）+History.init entryTurns（~9k row-ID 插入，incl 15.74%）+rows/navigation 拼接+joined O(output) 容器装配（incl 13.43%）+全窗验证——**O(窗口) 在全局字典/集合/容器，per-turn 投影已 O(页)**。**流式链路构成**（评审精确口径：事件解码 inclusive 40.4%，decode-free n=12,272 为链构成）：arc-copy 17.9%+utf16-bridge 17.6% 分散机械、**find inclusive 27.3%**（=bench query_update 0.25ms 吻合；innermost 口径 ~2% 系 find 内部 ARC/哈希散落通用区域之低估——rounds 27-33 消除的是重建机械，留下的是设计内残项：整窗前缀验证+后缀路径+零拷贝 hits）、narrative 12.2%（incl 13.1%，round-20 否决在案）、cf-match 11.1%=live-turn 真实匹配、input-compare 6.9%；相位切分敏感性披露（双规则边界样本 14.5% 不一致、计数一致；归档输出评审复算逐值一致）。**流式方向不立项**（无单点主导+narrative 否定清单+匹配语义红线）。**round-35 候选方向草图（评审 F1 重构）**：turn 记忆化已存在，候选=**全局索引 prepend 感知增量化**（owner/entryTurns/turnAnchors 序号平移+新页增量插入，O(页 identity+turns) 替代 O(窗口 identity)；prefixIdentities 增量 union）+**容器装配**（rows/navigation O(output) 拼接的分段/持久结构评估）+**键驻留**（同批 id 跨三字典反复哈希）；预期 older_page -40~60%（4.1→~1.6-2.5ms 可测面充分，机制份额不因表述修正而变）；设计问题（owner 重复检测语义与 prefixIdentities 全集语义的增量等价保持、序号平移的位置消费方梳理、缓存层五点论证、失效语义沿 round-12/30/32 谓词族）+红线（展示层等价钉死密集、断言零放松）+风险（折叠/可见性正确性=用户可见缺陷类，钉死密度对齐 round-30/32；重复 id/跨页 turn/页边界矩阵）。**评审处置**：第九次中间摘要结束但 **verdict 提前落盘**（review-findings.json：BLOCKING 1=F1 因果链与源码矛盾，source_evidence 四处；开发机独立源码复核一致+剖面佐证；记录级更正免新复核轮）；评审复算双 XML sha256/归档输出逐值一致/prepend inclusive 消费者/decode 污染口径/find 双口径全部并入报告。队列重排：①分页全局索引增量化（round-35 优先）②streaming input-compare（尾部限定需前缀不可变证明+红线评估，暂不立项）③narrative（round-20 否决在案，重估须新机制）④find-bar 双形态 closed⑤旧余项不变。XML 留机不入库（round-15 先例） | [round-34](2026-11-17-round-34.md)；[归因](round-34/attr/)；[#356](https://github.com/chenweigao/perch/pull/356)，merge=529d41e |
| 35 | 2026-11-17 | 分页全局索引 prepend 感知增量化（owner/prefixIdentities/entryTurns 相对序号+基数平移+COW 复用+合并容忍≤1 首 turn 消费） | **采纳/已合并（merge=fd79884，PR #357，终 head a05c36c；Mac 仲裁；采纳数据 v3=740b5f2e；测量迭代 v1=a3c1f13→v2=0581fea→v3=740b5f2e；基线=529d41e）**：older_page_full_chain **Mac 4.125→2.665ms=-35.39%**（六对全分离，worst -32.60，spread 6.13）/ Linux -42.75%（六对全分离），round-34 预估 -30~50% 区间落地；v1 merge 基数 off-by-consumed 真实缺陷（byTurn 键全体越界→overlay 全丢）被**全行 overlay 钉死**暴露→v2 修复；**v3=评审发现闭环**（增量 identity 集减消费项丢失 observed 并集成员——remembered live tool 的 call 随被消费 turn 消失、其尾部结果 separates 误放行 separable 翻转；修复=减集后补回 observed 项；成立范围比评审表述更宽：anchor 迁移同为 term 变动源，cachedObserved==observed 守卫不覆盖 anchor 变化）+**投影级 kill 钉死**（模型级 fresh 参考对此类缺陷盲——首 observe 活工具在当前 anchor 下 term 恒空；discardPrefix 参考保观测历史+kill 序列=自身 split 观测→增长→压缩替换首 turn→尾部结果翻转 separable；变异态击杀 exit=132 双确认）；Mac 90 项原批 2 positive 越带（longtail200_narrative +6.53/total +5.47，六对同向）→**同 sha 六对复测定性=运行级环境波动**（复测 -0.39/-0.10 不复现不分离、Linux 同指标 -0.18 反向带内、narrative 阶段与改动行无调用路径、presentation-token 全家族 +1~2% 整体偏移后全数回带；原批 spread 异常紧 5.55 令批间微小偏移越带；round-33 edit 族同型处置）⇒ **复测后零带外回归**；Linux 96 项 NONE；护栏全带内（Mac presentation_update/chain_total/query_update +0.00%、reopen -1.26% 带内）；fail-safe 变异体如实记录（TV owner 基数/消费四变体→anchored 重复检查或过拒绝→整窗回退输出正确，A/B 幅度承载防线；history-consumed-removal-skip=合并 turn 全量重插逐位覆盖⇒等价）；**电池 v3=4 kill**（history base×2、suffix 弱化、tv-no-restore）+5 记录存活；钉死=10 场景组差分（模型级 9 组+中毒阶段+投影级 consumed-term）全行 overlay 比较+既有钉死族零改动全绿；checks Mac 110/base 109、Linux 109+1 SKIP/108+1 SKIP；候选重建字节一致（Linux ec3f58ee 三点一致；Mac 批内首末一致），基线重建不一致=**环境非确定性第 34 例**（基线侧模式延续）；**CI**：0581fea math flake（variance family 签名：基线三轮 2.4x 跨度含 warm-up 尖峰 vs 候选紧凑且中位更快 0.944）经静机复测 PASSED 0.9467/0.9958+同 head attempt-2 success **双绿取证闭环**；740b5f2e 双工作流首过全绿；portable 10/10 @740b5f2e（dirty=报告/证据 untracked 披露，round-32 先例）；**评审** kimi-code gpt-6.1-sol options {}（**schema 变更披露：thinking 选项被 provider 移除**，orchestrator_capabilities 复核后默认 mode 发货）第 10 次 interim 结束、verdict PENDING 早期持久化（interim 无 verdict 第 6-10 次复发，缓解措施生效）、唯一发现采纳为真实缺陷 v3 闭环（round-30 v5 先例：评审明示更正+自查验证免新复核轮）、评审侧 ab-audit Linux v2 96 指标×480 字段重算 statistic_mismatches=[]/positives=[]、未完成 identity-subtraction-probe 与最终 kill 序列同构存档；分析器 analyze_r35.py 归档并**以 v2 双端 summary 零偏差复现先行验证**；**停止规则计数归零（1/3→0/3）** | [round-35](2026-11-17-round-35.md)；[A/B](round-35/ab/)；[变异](round-35/mutations/)；[评审产物](round-35/review/)；[CI 取证](round-35/ci/)；[portable](round-35/portable-results-740b5f2.json)；[#357](https://github.com/chenweigao/perch/pull/357)，merge=fd79884 |
| 36 | 2026-11-17 | 分页链路 post-round-35 归因刷新 + joined foldParents 沿 prepend 对齐的 COW 收养（消灭每次 prepend 的全窗字符串键 parents.merge） | **采纳/已合并（merge=b8e2d7a，PR #358，终 head f40aa5d；Mac 仲裁；采纳数据 v3=1226a2f8，产品字节=v1 c987ff9c；测量迭代 v1→v2=0c42b7d3→v3=1226a2f8，v2/v3 仅测试字节；基线=fd79884）**：归因刷新（Mac Time Profiler @fd79884，1020 prepends）确证 round-35 达成（projectTurns consumer 5.09%→**0.64%**、History.init 跌出前八）并定位新首位=**History.joined inclusive ≈12.5% of prepend**（string-hash 1129 样本=6.67%[评审复核 6.6706%]+dict-find 3.25%+string-compare 2.27%）——每 prepend 新 History 实例 memo 必失效 ⇒ 全窗 folded ids 重做字符串键 merge；候选=init 时捕获 prior joined memo（rows/foldParents COW 引用+consumed 行数/fold keys+leadingNew；**不持 prior 引用**——presented 时旧 History 通常已释放，weak 方案在 bench 路径永不生效）、presented 以 COW 收养：consumed keys **删除先于** leading 插入（merge 重携语义）、leadingParents current-wins 累积后覆盖收养字典（earliest-wins 与全量 merge 逐位一致）、rows 平面装配不收养（memcpy 最优）；门=双 uniqueEntries+双 activity 空+foldsProcess 相等，任一失败回退全量。**Mac v3：older_page 2.660→2.070ms=-22.18%**（spread 10.31，worst -19.25，六对全分离；v2 批 -24.77% 同幅度）；Linux v3 -25.22%（spread 5.74 三轮最紧，六对全分离）；**双端 positives 全零**（90/96 项）；护栏全带内；**两轮累计 Mac older_page 4.125→2.070=-49.8%**。**钉死三事件如实入册**：①harness reseed 盲区——compare() 末次调用带 overlay ⇒ 捕获门恒拒 ⇒ 差分全程不触发收养（修复=每步纯形态 reseed+反盲断言）；②v2 电池 **wrong-order 存活=fixture 等价**（splitAt=3 消费/leading 折叠键集不相交，trace 实证）⇒ v3 splitAt=2 制造 call-C0-0 重携后**击杀**（exit=132 预验证）——正确性关键顺序语义必须有使其可观测的 fixture 形态（round-33 消费级钉死教训同族）；③场景 11 overlay-last 门钉死（gate 变异体击杀 :361）。**电池 v2=4 kill+2 记录存活、v3=5 kill+1**（prior-uniqueEntries 门=结构性不可达：重复 id 窗口在 TV 层永久毒化 chunk 路径）。**评审两段均 interim 结束（第 11/12 次，verdict PENDING 持久化）**：R1（RECORD：6.67% 转写+深走查归档缺失）闭环且**评审方复核销项**；评审侧完成 A/B 复算（Mac 89×445/Linux 96×480 零失配零 positive）+归因数字复核+独立 checks 109+1+源码门控确认（捕获时序/turn memo 改写安全）；**等价性 oracle 探针由评审设计、任务时限中断构建、开发方续建代跑 exit 0**（私有产品副本内注入收养 vs 全量 joined 逐位断言+consumed 前缀形状 precondition+fold×consumed×leading 触发矩阵，形态披露）；displayMessages.getter 2.7% 归因存疑不立项（WorkbenchCore 无调用方，疑内联符号化伪差 F3 口径）。CI：1226a2f8 双工作流全绿；4f6999e8 math 门槛 flake=**第 37 例**（超门限 0.47ms，attempt-2 绿）；f40aa5dd 三段取证：session GUI 录制超时=**第 38 例**（attempt-2 绿）+ math 双败=**第 39 例**（失败尺寸 128↔32 游走、同尺寸中位比跨 attempt 摆动 0.86→1.35、基线离散 2.71x；**静机复测 PASSED 三尺寸全 ≈1.00**（best_ratio 1.0084/0.9979/1.002，完整门槛协议 @PR base）+ attempt-3 15/15 绿；同产品字节此门累计 4 绿 3 红=variance family 闭环，门槛零改动）；候选重建字节一致连续第三轮、基线重建不一致=**环境非确定性第 35/36 例**；portable 10/10 @1226a2f8（dirty=证据未提交披露）；续审构建与 Linux pair5-6 计时窗重叠——逐对检视无差异、spread 5.74 最紧 ⇒ 无污染批次有效（披露）。**停止规则计数维持 0** | [round-36](2026-11-17-round-36.md)；[归因](round-36/attr/)；[A/B](round-36/ab/)；[变异](round-36/mutations/)；[评审产物](round-36/review/)；[portable](round-36/portable-results-1226a2f8.json)；[#358](https://github.com/chenweigao/perch/pull/358)，merge=b8e2d7a |
| 37 | 2026-11-17 | 分页链路 post-round-36 归因刷新评估轮（成本地板判定；displayMessages 归因未决收口撤回；双层验证发现入队列；未立项） | **评估轮/未立项/已合并（merge=6ac65f9，PR #359，终 head 65f2938；docs+归因轮：`git diff b8e2d7a HEAD -- Sources/ Tests/`=0 行；停止规则计数 1/3）**：归因作业 @b8e2d7a（Mac Time Profiler PAGING 形态，harness 血统 round-34/36；本地保真干跑先行 triple 4.655 vs bench 5.18ms 比率 0.90 血统带内；分析器与 r36 逐字节同）——**rounds 35/36 达成确证**：string-hash 深走查总量 4.17%（r35 侧 9.83%）、dict-find 1.74%（r35 侧 4.60%）、history-join 0.27%、joined 残留 0.41%、joinedIncremental COW 成本实测 1.21%=设计预估下沿；**地板判定**：ARC/bridge 42.91% 主体=值语义固有 churn（update() 内联 15.14%=previous=input 替换的旧窗 16k 元素释放链、Input public API=红线；History deinit/init 3.9%、字典析构 3.1%、teardown 8.83%）+正确性门槛（sameWindow 族 ~5%、cost-reuse 深值 == 2.78%=缓存准入语义门 budget-0 钉死族）+narrative 5.68%（round-20 否决）+其余已增量化（timeline-make 2.26%/normalize 1.59% 源码核实 split 仅尾段/projectTurns 1.17%）——可攻单点均 ≤3.5% 低于分类器可信阈（spread 4-10%），不立项；**displayMessages.getter 3.37% 归因未决（评审 F1 BLOCKING 撤回初稿「符号化伪影收口」）**：harness 实际三处调用（r37-attr.job:122/148/153）+in_flight_turn 非空 ⇒ 走 O(窗口) messages+[live] 拼接（ConversationTimeline.swift:221）而非 O(1) early-return；prepend 相样本或含 warm 段相位边界污染（next-marker 规则，round-34 14.5% 先例）；无探针/DWARF 实验不得宣称伪影（round-33 F3 撤回先例）——维持未决推断/暂不选题；已确证边界=分页 20 页循环体内无调用、model.update→cache.retain 链无调用、产品侧调用在 AgentWorkbench 红线区（9 处，R1 更正初稿 5 处）——**流式形态每更新 O(窗口) 拼接（getter 本体在 WorkbenchCore 可攻）并入 round-38 流式复剖裁决**；**双层验证发现（评审 interim 更正措辞）**：cost-reuse 深值 ==（~2.8%）与 TV chunk 验证（~5%，位态结构层 sameWindowBits 73B/消息优先+深值回退，KimiProtocol:314-321）每 prepend 各扫描同一后缀窗口——深度与语义不同，去重可行性取决于位态层能否覆盖 cost 准入等值需求（需红线评估+精确语义分析）；物理同一性快路径（buffer 地址比较+精确回退，语义零变化）估算 2.8-3.5% 低于阈值不消耗正式轮；**评审**（第 13 次 interim 无 verdict，PENDING 早期持久化）：F1 BLOCKING+R1 RECORD 全部照改（记录级更正免新复核轮先例），verified 7 项（**归档表 212 个百分比独立复算零失配**、零产品 diff、settle 谱系、分析器逐字节同、region 余量 9 正常），outstanding 5 项如实披露；portable 10/10 @fba41fb1 **dirty=false**；CI：65f2938f attempt-1 app-launch GUI 超时 flake（**第 40 例**，#25/#31 族；TimeoutExpired→killpg PermissionError 未捕获升级为脚本崩溃——check-functional.py 超时清理健壮性缺陷入 backlog，非循环范围）+attempt-2 15/15 绿双证据闭环，门槛零改动；**队列重排：①流式链路复剖（round-38 首选，含 displayMessages 拼接裁决+find 残项刷新）②双层验证统一（红线评估）③narrative 新机制④cold/find 封闭依旧**；停止规则计数 **1/3** | [round-37](2026-11-17-round-37.md)；[归因](round-37/attr/)；[portable](round-37/portable-results-fba41fb1.json)；[#359](https://github.com/chenweigao/perch/pull/359)，merge=6ac65f9 |
| 38 | 2026-11-17 | 流式链路复剖（post-rounds-35/36）+ narrative tool-step 解析全值验证记忆化（NarrativeTextCache.resolution，steps() 同款教义） | **采纳/已合并（merge=待下轮 settle 回填，PR #360；Mac 仲裁；采纳数据 v1=80969b9d 单版本通过；基线=6ac65f9）**：归因刷新（STREAMING 形态，decode-free n=12,285，decode-ancestry 40.48%=r34 口径吻合）——**narrative make() inclusive 22.23% 为最大产品 consumer**（95.8% 单一入口；叶=分散字符串/CF/本地化机械；机制=每 delta 对 live turn 全部 tool steps 重做纯函数解析）；**displayMessages 6.79% 定量收口（round-37 F1 遗留）但不立项**——eager 缓存令 paging 每 prepend 回归 ~2-3%、惰性 memo 被非 mutating getter（public API 红线）+Sendable struct 值语义双重封死、box-lazy 单调用方零收益（结构性论证入档，队列待 API 层评估）；joinedIncremental 流式 0%=round-36 设计确证。候选=tool 解析四元组（phase/target/headline/incidental）入 NarrativeTextCache：**键=tool.id、验证=完整 VisibleTool 值相等**（全值教义：状态/输入/输出/进度任一变动必重算，输出逐位一致由构造保证）、驱逐 65536 全清（steps 同款）、上下文相关 stage 装配不入 memo。**Mac v1：chain_total 0.600→0.460ms=-23.33%**（六对全分离，worst -21.67，spread 8.47）+**presentation_update -51.85%、stage_narrative -76.47%、stage_total -50.94% 次级分离**——远超 -6~12% 预估（预估仅计字符串机械，未计 CF/本地化/ARC 级联）；Linux -13.75% 六对全分离（与哨兵 -13.7% 逐值吻合）；older_page -5.28% 带内顺带受益；**Mac 91 项 positives 全零**；Linux 3 项 edit512 族 positives=**布局伪影三重定性**（机制排除：ActivityNarrative 与 fullLineDiff 零调用路径；Mac 同族带内 insert -0.15/unchanged +0.42/unicode -0.09；**同二进制本地六对复测**：漂移复现且原批 3 项全数回带+仅 trailing_empty 新越带=确定性 per-binary 漂移，round-13/33 家族；测试字节移动诱因在案；复测系统性 +1~5% 如实披露）；钉死=checkToolResolutionMemo（shared-vs-fresh cache oracle 差分，8 步值变化序列【status 迁移/input 变动/wait 类/值回访】+反盲断言）——**no-validation 变异体死于既有 PresentationHistoryTests:140（双钉死覆盖）、status-only 变异体死于新钉死 input 变动步**；电池 2 kill + 2 输出等价存活（eviction-removal=仅留存；key-by-name=全值验证兜底、仅缓存颠簸——证明正确性由验证承载而非键设计）；control Linux 110+1/Mac 111；候选重建字节一致**连续第四轮**（762f1570），基线不一致=**第 41 例**；CI 80969b9d 双工作流首过全绿；portable 10/10 @80969b9d（dirty=证据未提交披露）；评审 <!-- 回填 -->；**停止规则计数归零（1/3→0/3）** | [round-38](2026-11-17-round-38.md)；[归因](round-38/attr/)；[A/B](round-38/ab/)；[变异](round-38/mutations/)；[portable](round-38/portable-results-80969b9d.json)；[#360](https://github.com/chenweigao/perch/pull/360) |

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
- **正确性轮（契约断言类钉死）：计时源码树双侧除 product patch 外必须
  相同；基线 trap 是证据不是门槛**（round 24 粗筛 v1 设计缺陷教训，表述
  经评审 F4 更正）：契约断言类钉死（如零缺口断言）在未修复基线上必然
  trap——这对 checks 是正确的（trap 即缺陷直接证据，记录之、不作门槛）；
  但若**计时**用基线源码树缺 tests 补丁，则双侧同时存在 tests 与 product
  差异，信号存在 tests/布局混杂**风险**（round-24 tests 改动 +80/−15；
  token2000_total 粗筛 v1 双端 3/3 正向信号在 tests 对齐 v2 与正式运行
  均未复现——正式 Mac +0.400858738%/Linux +0.880835905% 带内，0.00% 仅属
  Mac v2 粗筛；**具体因果归属保持 HYPOTHESIS**，未做反汇编取证，源码级
  提前返回不能推出生成指令不变）。规则：两侧计时源码树除 product patch
  外相同；编译配置、依赖、scratch 路径与各自二进制 hash 分别留存。
- **低延迟量级指标的 n=3 粗筛小样本信号不可作证据——受控性限定版**
  （round 24，表述经评审 F3 更正）：Linux v2 粗筛四项逐对 3/3 正向
  （token200_narrative +2.646374% 区间重叠、token200_total +2.406547%
  区间分离但中位变化<基线 spread、longtail 双项 +1.132390%/+0.814558%
  中位超自身 spread），正式 n=6 四项均带内。候选二进制跨批相同
  （dc6b16db），但**基线二进制不同**（f7dbea8c→354046d5），并非整对
  受控；候选自身跨批中位漂移 -4.6758%/-2.6444%/-0.3256%/-0.2980%——
  **两批数据不足以确定通用的 ±2～3% 噪声地板**，只能记录小样本信号
  未获确认与观察到的跨批漂移。不得跨指标借用 spread 裁决；这些是
  低延迟量级指标（PresentationBench 以整数纳秒写入 JSON），**非
  0.05ms 打印格指标**（打印格表述仅适用 ActivityBench %.3f ms 输出
  如 edit_stats@320）。
- **探针的输入新鲜度/缓存状态必须与产品形态同构——第五同构维**
  （round 25，评审 F1）：对同一组字符串重复预热后计时测得的是缓存热
  路径——stdlib `utf16.count` 热路径（ASCII O(1) 级、长 CJK ~1.4ms/GB
  "近免费"）与**首次计数**路径（新建 JSONDecoder 串 ~1283ms/GB）相差
  可达 ~300×，足以反转手写替代的优劣判定：冷字符串对照（构造在计时外、
  结果消费、七对交替）SWAR 快 **3.6154×/3.4240×**（评审原件+操作员
  复跑 checksum 一致）。凡以探针否决机制方向，必须核对探针输入构造/
  预热与产品负载的新鲜度分布同构（round-20/21 归因同构四维的探针侧
  镜像）。**utf16.count 手写替代方向未关闭**：热形态 stdlib 占优、冷
  形态 SWAR 占优，产品混合形态净效应待 Mac 上下文内粗筛裁决；勿引用
  round-25 初版热探针作否决依据。探针全套归档 round-25/probe/。
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

- **字节不变量的钉死必须用 UTF-8 字节比较，绝不能用 Swift String ==**：`==` 与合成
  Equatable 是规范等价——round-27 v3 钉死的跨制度/excerpt 断言因此放过了
  precomposedStringWithCanonicalMapping 注入的规范化变异体（复核独立 harness 实锤：
  oracle 100B NFD vs warm 99B NFC，canonical_equal=true/byte_equal=false）；v5 以逐 hit
  byteShape（entryID/excerpt/occurrence/toolID/toolOccurrence 序列化字节）+ Array(utf8)
  字面断言修复，三形态变异体双 harness 击杀。凡声称"字节级/逐字节"的断言先查比较原语。
- **夹具里的"重复 source"必须放独立 message**：同一 assistant 消息内相邻 text 部件被
  coalescingAdjacentAssistantParts 合并为单一 source（KimiProtocol），round-27 v2 钉死的
  重复部件因此从未行使同遍去重路径（6 出现/6 唯一/0 重复）。构造 source 级夹具前先核对
  时间线的合并/拆分规则（ConversationTimelineEntry.make 的 phase 切分）。
- **utf16.count 手写 SWAR 替代（ConversationActivity 热路径计数点）**：Mac 上下文内
  粗筛目标场景 single_turn_activity@2000 中位 -2.220680%（小于历史参考范围 3.94~7.50%
  ——未建立达门槛的收益证据），Linux 同指标两对同向不利 +5.703422%（本批内分离，作
  增强止步信号）。勿再以"SWAR 冷首数 3.4~3.6×"立项该替换（round 28）；实测回归的
  机制归因未建立（同形探针份额仅 ~0.77%，评审 F2——勿引用混杂的 4.5% 份额算术），
  且粗筛为 tests 未对齐的定向筛选（F4）。**不声称已排除所有混合负载净收益**。重开
  条件：产品路径转为冷/新解码字符串首次计数为主且归因份额超噪声地板，仍须 Mac 粗筛
  先行、强因果主张需 tests 对齐复测。

- **纳秒级指标（state_reset 族，~20-50ns）的相对百分比无意义**：原始计时为整数纳秒
  时间戳（round-27 复算：100 样本非整数者 0，.5 值为偶数样本中位），±10-20ns 即 +48%；
  该族跨批不可复现的越带一律按测量噪声 HYPOTHESIS 披露（round-22/26/27 同型），不得
  单独作为回归/收益证据。

- **成本公式必须对照类型全字段集逐项核对**：任意长度 optional（fileId）与数组
  元素结构存储（MemoryLayout stride × count）都是留存字段类——round-30 v5 公式
  漏掉三类（fileId/sourceEnds/结构存储），round-32 评审探针实测 8MiB/8MiB/12MiB
  滞留于账面 157B/20B/126B。委托断言（pin 直接调用被测成本函数）抓不到被委托方
  的缺口——手算公式必须独立展开。等值 String 的多份独立分配（推进链收养）不共享
  COW 存储——"计一次"声明必须由存储时规范化保证，不能假设。
- **A/B 分类器要求双侧等精度测量面**：单侧细化打印（候选 4 位/基线 2 位）会
  隐藏基线离散度——量化后的基线样本存在与之打印一致的潜在真值使
  max(两侧 spread) 被低估、|change|>spread 门失效（round-33 F1 见证：
  [0.0951×5, 0.1149] 打印同为 [0.10×5, 0.11]，spread 20.8% > change
  17.8%）。指标接近打印地板时，先升级双侧测量面再仲裁；基线侧允许
  test-only 打印 patch（产品树 pristine，patched fixture 哈希入收据）。
- **perf-only 旁路变异体需要消费级钉死**：存在性断言（表里有节点）杀不死
  "绕过命中分支/禁用转换路径"变异体（结果全对、优化静默失效）——用哨兵载荷
  （手工存入的可识别 hits）断言路径被实际消费；A/B 幅度是最后防线而非唯一防线。

## 候选队列（按当前证据排序）

依据 round-12 复剖（base=7d5ba26）与 round-15 三场景复剖（base=9c12eb9，
[归因](round-15/attr/)）重排：

**round-38 后记（narrative tool 解析记忆化落地，chain_total -23.3%）**（[round-38 报告](2026-11-17-round-38.md)）：
流式复剖裁决两件事：narrative make() 22.23% 立项成功——**全值验证
记忆化的收益远超叶机械份额预估**（-23% vs 预估 -6~12%：inclusive 口径
下 CF/本地化/ARC 级联全部随重解析消失），方法学教训=**立项预估应以
inclusive 口径为上界、innermost 叶份额为下界**；displayMessages 6.79%
结构性受阻不立项（eager 伤 paging、惰性被非 mutating getter+Sendable
值语义封死——公开 API 形态约束首次成为明确不可攻边界，入队列待 API
层评估）。全值验证教义第三次成功复用（entry cache→prefix cache steps
→tool resolution）：key-by-name 变异体输出等价的存活实证「正确性由
验证承载、键只是寻址」。edit512 族 Linux positives 第四次布局伪影
定性（三重证据+同二进制复测漂移复现），复测系统性 +1~5% 如实披露。
队列更新：①双层验证统一（红线评估）②displayMessages API 层评估
③narrative 残余（steps 派生的 live-tail 重扫描——cache.steps 对增长
entry 每 delta 全量重派生，增量派生需前缀稳定性论证）④cold/find 封闭
依旧。

**round-37 后记（分页链成本地板判定 + 双层验证入队）**（[round-37 报告](2026-11-17-round-37.md)）：
rounds 35/36 落地后分页 older_page 链达当前架构成本地板：ARC/bridge
42.9% 为值语义窗口切换固有 churn（previous=input 旧窗 16k 释放链，
Input API 红线）、正确性门槛 ~8%（sameWindow 族+cost-reuse 深值 ==）
不可削弱、可攻单点均 ≤3.5% 低于分类器可信阈——评估轮不立项（计数
1/3）。方法学三项入册：（1）**伪影判定必须实验证据**——F1 撤回
「displayMessages 符号化伪影收口」：harness 三处实际调用+in_flight
非空走 O(窗口) 拼接+相位边界污染可能；「归因存疑」只能维持未决不得
收口（round-33 F3 撤回先例的再发防线）。（2）**双层验证结构**：
cost-reuse 深值 == 与 TV 位态结构层+深值回退扫描同一后缀——去重
论证必须写明深度与语义差异，「同一字节双深走」为失准表述。（3）
**评估轮送审纪律**：零产品字节仍送审——F1 正是评审发现的 BLOCKING
级归因表述缺陷（round-34 F1 同型再现：归因轮的因果链主张必须逐处
源码对照）。流式侧队列新增：displayMessages live 非空每调用整窗拼接
（产品流式每更新支付；getter 本体在 WorkbenchCore 可攻）并入
round-38 流式复剖裁决。

**round-36 后记（joined foldParents 收养落地，older_page 再 -22.2%，两轮累计 -49.8%）**（[round-36 报告](2026-11-17-round-36.md)）：
归因刷新先行确证 round-35 达成（projectTurns 0.64%）并定位新首位
History.joined ≈12.5%——收养机制三点入册：（1）**捕获时机=init 而非
presented**（旧 History 在 presented 时通常已释放，weak 引用方案在目标
路径永不生效——生命周期分析先于缓存设计）；（2）**顺序语义的 fixture
可观测性**——wrong-order 变异体在 splitAt=3 下 fixture 等价存活（折叠键
集不相交），splitAt=2 制造重携后击杀：正确性关键的顺序必须有使其可观测
的形态，与 round-33「perf-only 变异体需消费级钉死」同族；（3）**harness
memo 播种盲区**——差分 harness 的调用序列本身决定收养路径是否触发
（overlay 末调用⇒门恒拒⇒全程盲），reseed+反盲断言+插桩 trace 计数
三件套为收养类机制的标准验证形态。评审协作新形态：oracle 探针由评审
设计、开发方续建代跑（私有副本插桩、逐位断言、矩阵覆盖），产物全档。
ARC/bridge 37.3% 为值语义窗口切换固有 churn（不可攻）；sameWindow 验证
族 ~4%（正确性门槛）；input-compare/narrative/prefix-verify 否定清单
依旧。队列余项：键驻留（同 id 跨字典反复哈希——joined 收养后剩余哈希
主体）、streaming input-compare（红线评估）、displayMessages 归因复核
（若后续立项需先解决符号化伪差）。

**round-35 后记（分页全局索引增量化落地，older_page -35.4%）**（[round-35 报告](2026-11-17-round-35.md)）：
round-34 首位候选方向单轮落地：相对序号+基数平移+COW 复用+合并容忍替代
owner/prefixIdentities/entryTurns 的 O(窗口) 哈希插入——Mac 仲裁 -35.39%
（4.125→2.665ms）/ Linux -42.75%，六对全分离，预估区间落地。方法学三项
入册：（1）**增量集合的消费减法必须补回 observed 项**——term 成员受消费
与 anchor 迁移双变动源影响（cachedObserved==observed 守卫不覆盖 anchor
变化）；**模型级 fresh 参考对此类缺陷盲**（首 observe 活工具在当前 anchor
下 term 恒空），kill 钉死须投影级 discardPrefix 参考 + 压缩消费首 turn +
尾部结果翻转 separable 序列。（2）**紧 spread 批越带模式**：原批 token
家族 +1~2% 整体偏移、仅 spread 最窄两项越带、同 sha 复测全数回带——
亚毫秒家族的正向越带先疑批级波动，复测后定性（round-33 edit 族同型）。
（3）**分析器归档纪律**：analyze_r35.py 先对既有 summary 逐字段零偏差
复现再出数。fail-safe 等价类扩展：TV 基数/消费类变异在输出层不可观测
（anchored 检查/过拒绝兜底整窗回退），由 A/B 幅度承载防线。容器装配
（rows/joined O(output) 拼接）与键驻留仍在队列首位。

**round-34 评估后记（分页/流式归因+round-35 方向）**（[round-34 报告](2026-11-17-round-34.md)）：
find-bar 之外的两个形态完成首剖。分页=**全局索引与容器装配层的 O(窗口) 重建**
（评审 F1 更正：turn 粒度投影复用已存在且生效——timeline-make incl 仅
4.16%；重建的是 owner/entryTurns/turnAnchors 字典 ~16k+9k 哈希插入、
prefixIdentities union、rows 拼接容器，incl：projectTurns 18.24%/
History.init 15.74%/joined 13.43%）——round-35 候选=全局索引 prepend 感知
增量化+容器装配+键驻留（预期 older_page -40~60%）。流式链路无单点主导
（narrative incl 13.1% 有 round-20 否决在案；input-compare 语义本体；
cf-match=live-turn 匹配红线），不立项；find inclusive 27.3%（decode-free
口径）=query_update 设计内残项（重建机械已消除，余前缀验证+后缀路径）
=七轮缓存化收益的定量确证。归因方法学入档：harness 本地干跑保真先行
（fixture 细节如 distinct-id 页池可致 7 倍膨胀）、相位切分用 harness 帧
标记（JSON/presented）、消费者归因表（hash/dict 叶→父消费者）。

**round-33 后记（守卫落地，reopen 0.077ms）**（[round-33 报告](2026-11-17-round-33.md)）：
reopen 剩余构成=整窗字节比较 ~27µs（26.9%，低成本路径，验证频率优化触
memo 红线）+结果装配/ARC 本体+后缀 per-entry ~20%——**reopen 方向关闭**：
0.077ms 已深入打印地板下两个数量级，产品不可感知，进一步立项缺乏可裁决
测量面与产品意义。query_update（流式重搜）本轮 -13.8% 后剩余=后缀 per-entry
round-30 路径+时间线合成，如需再优化须先建 µs 级计时面。cold 维持红线封闭
（78.5% cf-match+碎片化余量+store-walk 0.61%）。归因方法学新增：rule A2
（ARC 叶诚实分类）、双平台直接探针优先于 profile 叶符号推断（F3 教训：
release 内联下叶符号不可尽信，机制论断必须直接实验支撑）。

**round-32 后记（前缀缓存落地，reopen 进入 0.1ms 量级）**（[round-32 报告](2026-11-17-round-32.md)）：
三层跨实例缓存齐备（rendered source → entry → prefix）；reopen 形态从 round-30
的"逐 entry 验证+收养拷贝"（16.4ms）变为"一次窗口验证+不可变节点引用收养"
（0.10ms，已到 ms 两位小数打印地板——后续 reopen 优化不可再以该指标裁决，需
更细计时面或新归因）。reopen 剩余=窗口验证（bench 同数组 bitwise 短路；重建
窗口值层比较）+hits 数组拷贝+尾轮 per-entry round-30 路径+后缀搜索。cold 三批
一致付 store 走查（Mac 带内 +0.7~1.0%/Linux 分离 +3.1~3.9%）。**队列含义**：
①既有 reopen/cold 归因图（round-31）已完全变形，任何新立项前必须重打归因；
②cold 红线封闭不变（DD/CF ~79%）；③role 重排被前缀缓存吸收（reopen 剖面中
该路径已灭）；④双缓存并存的内存披露：entry 64MiB+prefix 128MiB+rendered
32MiB 上限（保守超估口径），产品实际占用远低于上限（bench 窗口单 prefix 节点
准入 <128MiB 实证）。

**round-31 评估后记（归因刷新+设计定稿）**（[round-31 报告](2026-11-17-round-31.md)）：
post-round-30 双形态构成图完成——cold 79% 双红线封闭（DD 内部 langid 11.18% 为最大
单叶但检测输出即契约；非红线余量碎片化 ≤4.6%/项）；reopen 15.69ms 几乎全部为每实例
结构开销（timeline-make 18.24%+cache-mgmt 18.97%+实例字典/teardown ~25%+verify 内务
~23%+role 5.15%；真实源重建≈零）。**round-32 优先候选=跨实例前缀（Earlier）缓存**
（设计五点点论证+留存成本模型+集成流程+尺寸预估 reopen→~2-3ms+钉死/保真/风险清单
全部定稿于 round-31 报告）；role 重排被其涵盖不单独立项。

**round-25 评估后记（更正版，评审 F1-F5；队列尚未穷尽）**
（[round-25 报告](2026-11-16-round-25.md)）：**存活候选**：
① ~~narrativeText 分隔符 range 搜索~~ → **round-26 已采纳移除**（字节
首次出现搜索+双侧边界证明+回落；Mac longtail_narrative -37.32%、
token narrative -13.45/-13.83% 六对全分离）；
② ~~utf16.count 手写替代~~ → **round-28 不采纳关闭（Mac 上下文内
粗筛裁决：目标场景 -2.220680% 未达门槛、Linux 两对同向不利 +5.703422%
增强止步；不声称排除所有混合负载净收益——评审 F1 口径；重开条件见
否定清单条目）**；③ ~~跨实例渲染缓存~~ → **round-27 已采纳移除、闭环完成（merge=b89851f；
三轮评审：初评 3B+9NB→v3、续验 N1 规范化断言缺口→v5 字节化、终版确认 v5 数据
零失配+变异体三形态终 head 击杀）**（RenderedSourceCache：五点设计论证过"不得全局 memo"
门（纯度按评审 F7 收窄为限定环境假设、驱逐 churn 成本按 F9 诚实披露）；
Mac cold -43.61%、reopen 候选内 -76.81%；探针揭示第二机制=同遍重复
source 去重（963 唯一/18,216 出现，夹具放大如实披露）；round-25 F7 保真
收窄以"既有指标注入新实例+reopen 单列+budget-0 无缓存参考端"落地）。**未选/缓议（非实质否决）**：
温路径地板（成本-收益暂不选；round-21 4.1% 系 cold 投影份额不可换算
温路径上限——F3；prefix memcmp/hits CoW 无独立归因、可省上限未知）；
lowercased()（0.22% 为全进程 self 叶份额、换算区域份额 ≈1.01% 仍非
inclusive 上限——F4；低优先未选）；缓存变体之 outputCharacters
（收益预期小暂不选题，份额混合比 4.54% 非同形上限——F2）；
TurnStatus.Progress.live dropFirst 与 **patchStat/changeStat 分行路径**
（均零 bench 覆盖=框架内不可裁决，未测缓议）；canonical 启发式
**重开条件保留、未立项**。dashboard 归因（环境、低优先）与 macOS
切换诊断（等用户输入；79～89ms 为历史引用值、原始工件路径待补——F9）
状态不变；红线域不变。

1. **find-bar 冷首搜与每 delta 地板**：round-15 复剖澄清 streaming profile 的
   search 区域（52.1%）主体是**每轮首查询的全窗冷搜**（产品对应开查找栏输入
   首字符；bench 每轮新建 ConversationSearch），由 CF locale 匹配（语义红线）
   与 ReplyDocument 渲染构成——优化空间在渲染/缓存结构而非匹配语义；每 delta
   温路径地板（prefix memcmp、hits CoW 拼接、最近轮 `ConversationTimelineEntry.make`）
   涉及 `ConversationFindResult` API 形状的改动会波及 UI，红线内先评估。
   **round-16 后记**：NSDataDetector 桥接块（~26%）已采纳移除（Mac 冷首查
   -19.75%）；余量：ReplyDocument.parse ~14%（cmark+normalizeDelimiters；
   循环形态重写需指令级新证据——round-15 collapsedWhitespace 粗筛先例）、
   CF 查询匹配 ~5.7%（语义红线）、~~跨实例渲染缓存~~（**round-27 采纳信号成立、
   待闭环**：WorkbenchCore 内有界缓存过设计论证门）与 UI 实例生命周期
   （AgentWorkbench 红线内不可动）。
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
   重写已在否定清单、trim 家族已在否定清单；**range 分隔符搜索已由
   round-26 采纳移除**）+ String 键表机制（字节键方向已关闭——round-21
   条目）+ 固定成本。**round-26 后记（评审 F3 更正版）：已处理当前
   已测的 phase（round-22）与无分隔符全文搜索热点（round-26 absent
   路径——正式六项主指标尾部夹具均无分隔符，证明的是 absent 路径
   收益）；命中/回落路径仍存在**：ASCII 后继使 beginsBindingMark
   保守回落（"a：b"/"a: b" 走 range(of:)——安全但未榨取；无任何
   binding 类含 ASCII，round-24 走查+ASCII 补查已证），其可采纳收益
   **尚未测量**；其余量未完成归因与裁决，**不宣称 narrative 机械
   空间穷尽**（命中路径确认化=潜在后续候选，round-26 合并后仍留
   队列）。presentation-token 场景余量转低。全局队列余量：cmark 本体/NSDataDetector 内部/CF 匹配（红线）、
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
2. **SessionEditStats 残余（小项）——round-25 低优先未选（非实质否决，评审 F4）**：
   `lowercased()` 每 tool_use 分配——0.22% 为 round-12 全进程 self 叶份额（含 62.1%
   setup），换算该画像 edit-stats 区域 ≈1.01%，仍非 inclusive 可省上限；Mac 历史
   spread 3.97～7.49%。据收益预期小暂不选；若立项需穷举非 ASCII 映射证明（round-22
   U+212A 机制可复用）。**patchStat/changeStat 分行路径（lines() 本体消费方）：
   零 apply_patch bench 覆盖，未测缓议**。
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
3. **小机械拷贝——round-25 裁决（评审 F6 更正名称/调用方）**：
   `TurnStatus.Progress.live(in:isRunning:)` 的 `Array(messages.dropFirst(start))`
   （产品调用方 KimiWorkspaceView:455/NativeAgentView:141；ConversationActivityBar
   调用的是 TurnStatus.init）——**零性能 bench 覆盖，框架内不可裁决**，未测缓议；
   复制；`ConversationActivity.outputCharacters` 对每个 text/thinking 走
   `utf16.count`（可参照 `KimiInFlight` 的既有缓存口径，不得引入全局 memo）。
4. **TimelineEntry.make——round-21 放弃叶级评估**（ARC 散点 ~4.1% 为
   **cold 投影区域**份额 + trim 家族否定清单 + API 形变红线）。评审 F3
   更正：该 4.1% **不可换算为温路径（find_bar_query_update）成本上限**
   （场景分母错配）；温路径地板整体为成本-收益暂不选，非实质否决。
5. **Mac mini dashboard 归因（低优先）**：`--mode all`/`dashboard` 在 Mac mini 上
   确定性失败（Missing directory scroll view，mounted=False 但 projection_matches=
   True）；SSH 与 GUI runner 两种上下文同样失败，GitHub CI 同代码通过——本机环境
   因素（候选假设：acceptance app 的偏好域残留、macOS 27.0.1 行为差异、显示器
   状态）。不阻塞轮次；归因前先跑一次全新偏好域 + --mode dashboard 单独复现。
5. **collapsedWhitespace 7 标量契约缺口修复**：**round-24 已完成**（钉死融合集
   U+0E33/U+0EB3/U+1F3FB–1F3FF + 走查 fusionGap==0 硬断言 + fast-path 专用模糊；
   双端无回归门槛通过；黄金摘要零移动；详见 round-24 行）。collapsedWhitespace
   字节重写方向仍在否定清单（round-15 粗筛 +16.56% 更慢）。
6. **CI 基础设施（非循环产物，待独立 PR）**：check-functional.py 超时
   清理路径 `os.killpg` 未捕获 PermissionError（round-37 #40 取证：GUI
   检查超时时清理崩溃把「可报告超时」升级为「脚本 exit 1」并掩盖原始
   签名）——建议 try/except 包裹 + 记录原始 TimeoutExpired。
7. **macOS 侧（等用户输入，可选加速项）**：真机切换会话 1.3–1.6s 卡顿归因需要
   用户日常使用中的诊断导出（perch-diagnostics.json）。合成 switching 基线已测：
   median 79–89ms，在产品目标内，无 20x 余量；冷启动 5/5 通过（时长指标待提取）。
   **round-25 评审 F9 限定**：79～89ms 为历史 INDEX 引用值，round-25 未复测，
   原始三轮工件路径待补；不据该历史范围认证当前用户体验或 FPS。
   frames/hitch 校准为 2026-09-23 起已知未通过项。
