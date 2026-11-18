# Round 3 / I01 独立评审处置

评审原件：[review-3.json](review-3.json)。观察／实际测试头：`025dc61cafa32e0e61eef2c4ef3ca8ea3a063d5e`。
限定结论 `PASS_LIMITED`，无新增 P1/P2、无阻断项。五项 P3 均为已有认证边界，不是新增回归；以下逐字保留 finding 与 required disposition。

## I01-R3-F01 — P3

> Linux portable 是实际候选的 10/10 通过且 dirty=true；Linux WorkbenchChecks 没有实际运行，保留日志仅为 swift: command not found。127 是既有前置失败记录，不是 WorkbenchChecks 测试结果，该单行日志也没有独立数字退出码行。本评审未在 Linux 重跑或把它改写为 PASS。

要求原文：

> 继续分列 Linux portable PASS、Linux WorkbenchChecks 前置失败/未执行与 Mac WorkbenchChecks 实际 PASS；不得用 portable 或 Mac 结果冒充 Linux Swift 执行。

处置：接受并保留。报告明确分列 Linux portable 10/10、Linux Swift 前置失败／WorkbenchChecks 未执行、Mac WorkbenchChecks 实际 PASS。原单行日志未改写或补造数字回执；127 只作为既有调用记录说明，不作为测试执行结果。原 portable 的 `dirty=true` 保留，源码另与候选逐字节核对。

## I01-R3-F02 — P3

> A/B 像素与 PNG 字节相同只认证这两个独立作业的捕获可比性，不能证明历史壁纸/tint 因果或所有未来环境稳定。系统全局明暗没有切换补测；源码 .system 返回 nil、普通路径不加背景及正常 native-design 的显式 light/dark PASS 是已核对范围，不是所有普通 preview 的完整人工交互验收或审美批准。

要求原文：

> 保留历史因果、系统全局切换与普通 preview 完整人工交互未认证的限制；仅对本轮源码不变策略、已执行正常路径和这些矩阵背书，不扩大成全产品或美学结论。

处置：接受并保留。A/B 结论仅限本次相同源码、机位与 fixture 的两个作业；未宣称未来全部环境、历史 wallpaper/tint 因果、系统全局切换或普通 preview 的全交互验收。原生 light/dark 与源码策略证据独立列出，不作审美裁决。

## I01-R3-F03 — P3

> S02 inspector 标题与 S03 Workbench preview 筛选器的既有截断仍在队列。I01 只证明本轮声明外没有新增像素改变，不能宣称全产品已经没有截断或重叠。round 2 仍是候选撤回、视觉 FAIL、完整契约 NOT_PASSED；本轮修复与限定评审不能改判该历史结果。

要求原文：

> 保持 S02/S03 未解决和 round 2 原判；评审文件不是同轮归档，round 3 目前不计完成，距汇报仍 18 轮，不开启 S02 或继续审美迭代。

处置：接受评审时的状态与边界，原评审不改写。评审完成时 round 3 尚未归档、仍余18轮；先原样收取评审、验证受保护输入，再完成本轮唯一提交归档，才可记本轮完成并将18改为17。S02/S03 仍是未解决队列项；后续 S02 必须新轮次、新基线、新证据与新评审，不复用撤回候选。round 2 原视觉 FAIL／完整契约 NOT_PASSED 保持不变。

## I01-R3-F04 — P3

> after-A/B 的完整源码头相同且 22 场景所有重复组合的原 PNG 字节相同，但原作业记录的 host 可执行文件 SHA256 不同。已核对原日志与发布日志的这些记录；本评审没有可执行文件原件来重新计算其 hash，截图稳定不能推出二进制一致或可重复构建。

要求原文：

> 保留不同的二进制 hash 为原日志值，源码头、bundle describe stamp、截图与二进制记录分开陈述；不宣称可重复构建，也不为此重派已完成作业。

处置：接受并保留。A/B 二进制 hash 仍是原日志值；相同源码、bundle stamp、原 PNG hash 与二进制记录不混同。未回收可执行文件原件重新认证 hash，不宣称可重复构建，不重派已完成作业。

## I01-R3-F05 — P3

> 预写差异清单 hash 在 before 原作业的捕获结果之前已有记录，三个 Mac 副本与本地原文逐字节一致，允许区 hash 与 after 副本也一致。现有只读材料可验证声明、冻结内容及作业条件，但没有清单/允许区首次文件写入的独立操作日志；不能编造首次写入时刻或证明封存之前从未发生任何改写。

要求原文：

> 保留原 hash 和既有时序声明，将首次实际写入时序注明为非独立认证；不得补造操作时间、运行证据，或用文件 mtime/Git 提交时间顶替首次写入日志。

处置：接受并保留。原清单、允许区与三份 Mac 副本 hash 均不改。报告原时序是本轮执行者的记录，首次文件写入时间没有独立操作日志认证；不以 mtime、提交时间或事后生成文件冒充首次写入回执。

## 父代理重验与归档边界

- 收取评审后，独立重算 `contracts/review-input-sha256.json` 的1719份保护输入摘要，全部一致；产品 Sources／Tests／scripts／CI 与实际测试候选零 diff。原评审 JSON 与全部原 PNG 不改。
- 本次仅补报告、处置文件、INDEX 与归档证据，不修改产品、不重跑 GUI、不重派旧评审。没有产品实质变化，故无新产品复核轮。
- 归档 SHA 与实际测试头分开：所有运行证据仍属于 `025dc61c`；最终归档头用 `git log -1 --format=%H -- docs/design/20x-style-rounds/round-3/review-3.json` 及外部交接核对。不得声称原截图运行于事后归档 SHA。
