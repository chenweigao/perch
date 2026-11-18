# Style loop round 3：Composer 捕获态背景基建修复

日期：2026-11-18。队列项：I01。状态：三层证据通过，独立评审 `PASS_LIMITED`，五项非阻断认证边界已逐字处置；本轮唯一提交归档。完成后距汇报为 **17 轮**；真实测试候选与归档头分开核对。

## 恢复与基线

- 用户于 2026-11-18 19:07（+08:00）执行 `/goal resume`，已从实际会话记录核验；原 blocked 审计重新开始。
- round 2 仍是视觉 FAIL、候选撤回、完整契约 NOT_PASSED；原图、评审与停止提交 `72a8690c` 不改写。
- 本轮 fetch 的 main 为 `65cf2fc67623a916f12797371d1ca087c911b24f`，新增仅性能报告与证据；已无冲突 merge。
- before 基线为 `5a4478eb317dc50321fbe4c28c034beaf5d53ec1`；相对 `72a8690c` 的 Sources、Tests、脚本、测量与 CI 零 diff。
- 性能循环在 main 的 INDEX 记录已停止；Mac PerfRunner 串行 runner 存活、队列为空，没有观察到正在计时的性能子进程。

## 单一区域、单一假设

Composer preview 根视图没有显式窗口背景；同机位、同 fixture 的历史中心色从
`(37,29,46,255)` 到 `(31,27,39,255)` 再到 `(30,28,37,255)`。
round 2 的原 RGBA 对照有 366106 像素共享 `(-1,+1,-2,0)` 位移；这是背景不受控的线索，不是壁纸因果认证。

本轮仅在 `StyleCapture.isRequested` 时，为既有 Composer preview 的窗口 container 使用已有
`WorkbenchTheme.contentBackground`。捕获辅助方法保留其他调用方原来的 clear 默认值；不改 theme token、
普通预览、主窗口、composer 原生 Liquid Glass、布局、字号、fixture 文本或用户设置。
具体预期在任何新截图和代码修改前写入 [expected-differences.md](expected-differences.md)。

## 本轮三层证据计划

1. 契约：WorkbenchChecks、portable、radius/localization、既有三 preview、生产 build 与 5/5 冷启动；正常 native-design 不再被错误身份格式断言跳过。
2. 视觉：新 before 的 22 场景双跑；修复后两个独立 PerfRunner 作业各跑相同 22 场景双跑，并全量跨作业零容差比较。
   before/after 仅允许 Composer 背景修复的声明变化；after-A/after-B 全部 22 场景必须零可见像素差异。
3. 回归：主窗口中英、默认／放大字号与 light/dark 组合；非捕获态外观跟随系统、fixture 默认 light 与既有玻璃契约保持。

使用原 `scripts/capture-style-loop.py` 与 round 2 已归档的 22 场景 wrapper；不重派任何旧作业、不替换 round 2 after。
每个新作业使用新的隔离 host app 路径；GUI／构建均从 PerfRunner 执行，不改 runner、权限、TCC 或 SSH 配置。
`style-r3-before-v1` 与 `style-r3-after-a-v1` 已完成并回收；after-B 只在 after-A 区域校验通过后排入，不把单作业通过当作修复完成。

### 已完成 before

- 原日志起点 `2026-11-18T19:31:39+08:00`，终点 `2026-11-18T19:38:44+08:00`，exit 0；pre/post porcelain 都为 0。
- [manifest](before/manifest.json) 的实际头为 `5a4478eb317dc50321fbe4c28c034beaf5d53ec1`；22/22 双跑 PNG 字节一致，共 44 张原图。
- [独立本地复核](contracts/before-self-comparison.json) 验证全部 hash、ready/window 元数据、语言／外观／字号与重复像素；22/22 零差异。
- 原图从 Mac 回收后逐文件比 SHA；发布副本仅脱敏文本路径，PNG 字节不变。before 的 host 与三个既有 preview 构建均成功。
- 预写清单 SHA256：`c3c9a8fb291d992228e99bdcd516834769dc6add0257b8d5bdffb4bae03ae67e`；Mac 输出副本与本地原文逐字节一致。
- [允许区](allowed-regions-before.json) 在原图与机位校验通过、任何预览代码修改之前固定；SHA256 为
  `3098322751a5bb89dd2d317807673e6d6120b17c2a15427e34451e282aa163b2`。
  仅两个 Composer 场景的窗口背景修复使用 `[0,0,760,500)`，其他 20 场景一律不允许变化；after 跨作业仍全部零容差。
- [原作业日志发布副本](contracts/mac-before/job.log) 与原件保留；不把排队时间 19:31:35 当作实际作业起点。

### 候选与已完成 after-A

- 唯一候选测试头：`025dc61cafa32e0e61eef2c4ef3ca8ea3a063d5e`。只改 `Tests/ComposerPreview/App.swift` 与共享捕获辅助方法；生产 Sources、theme、scripts 与 CI 零变化。
- 作业 `style-r3-after-a-v1` 实际起点 `2026-11-18T19:57:41+08:00`，终点 `20:04:02`，`.done` 存在、末行 `exit=0`；不把排队时间 `19:57:40` 当作起点。
- [manifest](after-a/manifest.json)：同一候选头、22/22 双跑 PNG 字节一致、44 原 PNG；host 与三个既有 preview 构建成功。
- [区域比较](contracts/after-a-region-check.json)：22 场景、零容差，清单外差异为零。Composer dark 改变 377957 个可见像素，中心 RGBA `[30,27,35,255]` → `[31,34,41,255]`；Composer light 仅窗口背景合成边界 `[0,32,760,33)` 的 760 像素改变，中心白色不变。其余 20 场景完全零差异。
- 本地查看 Composer light/dark 的原尺寸 before/after；文本、控件与 composer 几何保持一致，变化限定背景及其合成色，不据此认证历史壁纸因果。
- [回收校验](contracts/after-a-publication.json)：44 张发布 PNG 与外部原件 SHA256 一致；50 份文本只脱敏机器路径，原日志与元数据保留在外部 `raw/after-a/`。
- 冻结 wrapper SHA256 仍为 `21a8bb612056e9ce591525894401d957c2d8d869ef761eb26ecfef4529938473`；清单与允许区原副本 hash 均未变。
- `style-r3-after-b-v1` 于 `2026-11-18T20:10:43+08:00` 原子入队；模板在开始前要求 after-A 终结成功及上述区域检查 PASS。其完整结果与跨作业比较见下一节。
- 完整 Mac gates 仅在跨作业稳定性通过后于 `20:19:58` 排队；实际结果见下一节，bundle 的 describe stamp 与完整源码 SHA 分开核验。

### 已完成 after-B 与跨作业稳定性

- 作业 `style-r3-after-b-v1` 实际 `2026-11-18T20:10:43+08:00`–`20:17:00`，`.done` 存在、末行 `exit=0`；checkout 与 [manifest](after-b/manifest.json) 均固定候选 `025dc61c`，前后 porcelain 为 0。
- host 与三个既有 preview 再次构建成功；22/22 双跑字节一致、44 原 PNG 已回收。[发布校验](contracts/after-b-publication.json) 逐文件核对 PNG SHA256，文本只脱敏机器路径，原件外部保留。
- [before/B 区域比较](contracts/after-b-region-check.json) PASS，零清单外差异，与 before/A 的声明内变化一致。
- [A/B 稳定性](contracts/cross-job-stability.json) PASS：两个独立作业、相同源码候选、22 场景、无允许区、零容差，全部 22 场景零可见像素变化。
- [跨作业 PNG 字节校验](contracts/cross-job-png-integrity.json)：22/22 首张原 PNG 的 hash 相同；两个作业内的第二张也各自字节相同。不仅仅是忽略小 RGB 位移后的近似相等。
- A/B 的 host 可执行文件 hash 不同，原日志均保留；本轮认证相同源码与相同截图，不宣称可重复构建或二进制完全一致。
- before／A／B 共 132 张原 PNG。新增两张带标签的并排图是独立派生文件，原图不改字节、不缩放／裁剪；[派生索引](comparison/index.json) 记录来源与 hash。
- 回收 after-B 与派生对比后的 round-3 snapshot 发布检查为 727 files／0 findings。

### 已完成 Mac 完整契约

- `style-r3-gates-v1` 实际 `2026-11-18T20:20:00+08:00`–`20:23:10`，`.done` 存在、日志末行 `exit=0`；[原作业日志副本](contracts/mac-gates/job.log) 与 [汇总](contracts/gates-summary.json) 保留。前后 porcelain 为 0，完整 checkout SHA 为候选 `025dc61c`。
- [生产 build](contracts/mac-gates/build.log)、[Mac WorkbenchChecks](contracts/mac-gates/workbench-checks.log)、[radius](contracts/mac-gates/radius.log) 与 [localization](contracts/mac-gates/localization.log) 全部实际执行成功；不是仅模板语法通过。
- [冷启动结果](contracts/mac-gates/app-launch/result.json) `passed=true`、`completed_launches=5`。bundle revision 与本机同 checkout 的 describe stamp `v0.8.1-312-g025dc61c` 一致；另由日志核验完整源码 SHA，不把 describe stamp 当作 40 位 SHA。
- [正常 native-design](contracts/mac-gates/native-design.log) 实际运行并 PASS，27.94 秒；包含生产 workspace、回复／composer 对齐、集成 inspector、原生 light/dark、引用与 sidebar 交互，结束后有 fixture preferences 清理回执。未跳过该阶段。
- 原生运行另外回收 12 张原 PNG 与布局 JSON；[发布校验](contracts/gates-publication.json) 证明原 PNG 字节不变。人工查看全部原生截图缩略图，并全尺寸核对 hover／dark 引用截图；内容是合成 fixture，hover 路径是临时 fixture 目录而非个人 HOME。
- Mac 的受保护 Sources 与测量／CI diff 均为空；本地 `source-scope.json` 额外证明所有生产 Sources（包括 AgentWorkbench）本轮也零 diff。
- 本轮原截图总数为 144 张（三矩阵 132 + 原生运行 12）；两个并排对比为另行索引的派生图。原始完整输出在外部 `raw/gates/`，发布文本仅机器路径脱敏。
- gates 回收后的 round-3 snapshot 发布检查 759 files／0 findings；此前 [全分支发布检查](contracts/public-source-post-captures.log) 5638 files／0 findings。提交前继续使用现有发布门禁，不改检查语义。

### 已完成本地契约

- 实际候选 `025dc61c` 的 [Linux portable](contracts/linux-portable/results.json) 10/10 PASS；radius 与 localization 检查通过。原结果的 `dirty=true` 保留，不宣称整个工作树 clean；本次 [源码范围核对](contracts/source-scope.json) 另外确认实际源文件逐字节匹配候选，报告与旧未跟踪证据不伪装为源文件修改。
- 本机没有 `swift` 可执行文件，Linux WorkbenchChecks 未执行；[失败记录](contracts/linux-workbench-prerequisite.log) 仅含 `swift: command not found`，未含独立数字退出码行。127 是既有调用前置失败记录而非测试结果，不补造回执，不宣称 Linux PASS；Mac WorkbenchChecks 则已实际执行通过。
- [比较器自检](contracts/comparer-self-check.json) 与 [端到端控制](contracts/comparer-controls.json) 已通过；错误 PNG hash 与有效元数据下的单个清单外像素都被拒绝，未改动历史证据。
- after-A 回收后的 round-3 snapshot 发布检查为 485 files／0 findings；图像内容另外人工核对，模式扫描不替代视觉审阅。
- [回归观察与未认证边界](contracts/regression-observations.md) 保留 S02/S03 的既有截断；本轮不宣称全产品已经没有截断。正常原生 light/dark 运行已通过；未更改系统全局明暗来补做额外操作。

## 已知限制与纪律

- 已在有效 before 与允许区固定之后修改预览代码；本轮不直接重试 S02/S03，也不解除历史视觉失败。
- 任何未声明差异、跨作业不稳定或未执行的契约仍如实失败；不扩大旧 round 2 的允许区、不忽略 RGB 位移、不挑选截图。
- 本轮只读源文件发现曾因无匹配的 scoped AGENTS 搜索返回 exit 1 而提前结束一组读取；已补读，没有 GUI／构建或源文件修改。
- 独立评审使用 `acpRegistry_kimi_code`／`aone/gpt-6.1-sol`、`thinking=max`，只审契约与边界，不裁美；结论与同轮归档之前未推进计数、未开始 S02/S03。
- 原清单／允许区首次实际写入时序没有独立操作日志；此前先写清单再改代码的描述为执行者记录，hash 与副本一致性可以核验，但不认证首次写入时刻或封存前从未改写。不以 mtime／提交时间替代该缺失日志。
- 未开 PR、未向 main 合并；全部报告、截图与评审在本轮同一 conventional commit 归档，S02/S03 后续仍须各自新轮次证据。

## 独立评审与同轮归档

- [评审原件](review-3.json) 结论 `PASS_LIMITED`，无新增 P1/P2、无阻断项；独立核验144原PNG、完整Mac gates 与1719保护输入，五项P3仅为必须保留的认证边界。
- [逐字处置](review-disposition.md) 保留五条 finding 与 required disposition。原评审观察时 round3 尚未归档、仍余18轮，保持原文；同轮归档完成后才计完成、改为17，不反写评审历史。
- 父代理收取后重算1719保护输入，摘要全部一致；仅更新本轮报告／INDEX／处置及归档证据，所有生产和捕获源码与候选不变。没有新产品实质变更，无须重派已完成评审或GUI作业。
- 实际测试头始终为 `025dc61cafa32e0e61eef2c4ef3ca8ea3a063d5e`；本轮最终归档头通过 `git log -1 --format=%H -- docs/design/20x-style-rounds/round-3/review-3.json` 核对，并记入外部交接。`review-3.json` 的历史 `archive_head=null` 不改写。
- 2026-11-18 21:05 的现场 goal 曾为 paused，仅收取评审与更新外部暂停交接，未提交／启动S02；21:09再次核验goal active 后才执行本轮归档。不将异步评审完成当作恢复指示。
- 首次归档暂存检查在提交前因四份原始构建日志／捕获的源码diff尾随空格退出2，未执行commit／push；[校验记录](contracts/archive-validation.json) 保留全部诊断。原证据不裁剪／归一化，精确排除这四份原件后其余全部暂存文件（含手写报告）检查通过，不修改检查语义或掩盖源码问题。

## 截图索引

before：[22 场景索引](before/manifest.json)；after-A：[22 场景索引](after-a/manifest.json)；after-B：[22 场景索引](after-b/manifest.json)。全部属于本轮原件，不以旧轮次截图代替。

最终修复对比：[Composer light](comparison/composer-light-before-after.png)／[Composer dark](comparison/composer-dark-before-after.png)，来源为本轮 before 与 after-B。
