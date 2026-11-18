# Style loop round 4：inspector 标题宽度契约修复

运行／独立复核日期：2026-11-18；归档接续日期：2026-11-19。队列项：S02。状态：真实测试头`4b647966`的三层运行证据与有限独立契约已闭合；原FAIL保留，新独立目视补证PASS_LIMITED，无新增P1/P2/P3。同轮首次归档／精确远端核验已通过后计完成，距汇报16轮；计数随同一轮提交归档，最终归档SHA不冒充新GUI测试。

## 基线与单一假设

- round3已同轮归档并核实远端 `aad604b9ce5294b52951f189b3895b69edd12f31`；实际I01测试头仍 `025dc61c`，五项认证边界保留。
- 本轮开始重新fetch main与style分支；main仍 `65cf2fc67623a916f12797371d1ca087c911b24f`，已在分支中，无新增merge。性能循环INDEX明确用户于2026-11-18确认结束；串行PerfRunner存活，未观察到计时作业。
- 产品基线为 `aad604b9`；只计划回收 `ChangesInspectorView.header` 外层四段6pt空隙，不改其他间距、控件、字号、padding、inspector宽度或行为。
- [预期差异](expected-differences.md)与[允许区](allowed-regions-before.json)在本轮新截图和产品修改之前写入，写入命令的前置不存在检查、时间范围与内容hash另归档；不以mtime替代首次写入证据。
- round2仍是撤回、视觉FAIL与完整契约NOT_PASSED；本轮使用新作业、新host app与新截图，不复活其候选或改判历史。

## 三层证据契约

1. 契约：Mac WorkbenchChecks、portable、radius/localization、三个既有preview、生产build与5/5冷启动；正常native-design实际执行。
2. 视觉：新before/after各22场景×2重复；同机位、同fixture与精确源码头。仅已声明header矩形允许变化，其余像素零容差；分别查看中英、默认/放大与light/dark的完整标题和计数。
3. 回归：系统外观策略、Settings覆盖与fixture默认light不变；原生玻璃和已裁决方向不变。已执行范围与未认证范围分列，不用静态源码代替运行证据。

GUI与构建仅PerfRunner；共享Mac工作树每作业fetch并detach到所需已推送头。新作业使用新的结果目录；所有旧作业/旧评审已终结，不重派。

## 证据与纪律

- before计划作业 `style-r4-before-v1`，冻结22场景wrapper SHA256为 `21a8bb612056e9ce591525894401d957c2d8d869ef761eb26ecfef4529938473`。
- [写入回执](contracts/declaration-write.log)记录新目录前置不存在检查、apply_patch结果与2026-11-18 21:19:59写入完成；清单SHA256 `8bc899da4c896f1cdc8a99520dbba081955dd5b6f10a3d84641c04841e5b7be4`，允许区 `3002366930e124e2e335abd1d97730115b3dac31a7506f771087a36faafeb115`，均先于[排队回执](contracts/queue-before.log)21:20:29。回执是本次命令实际观察，非mtime推断，亦不改判round3首次写入缺少独立日志的限制。
- 允许区来自已验证的既有机位，但本轮须用新before重新核对。before通过前不改产品；清单外差异先撤回/停止，不扩大范围。
- 产品实质修改之后必须新的独立评审；round3的PASS_LIMITED不是S02的复核。
- 没有新preview、验收页重设计或其他平台；不碰测量/CI语义、真实连接或凭据，不开PR或向main合并。
- 新before于21:27:23终结，22场景双跑、44原PNG字节相同；[核验记录](contracts/before-validation.md)、[完整CLI控制](contracts/comparer-header-cli-controls.json)与[发布原图](before/manifest.json)已归档，不用旧轮图替代。
- 产品候选只把外层 `HStack(spacing: 6)` 改成0；不改内部6pt、Spacer4pt、控件、padding、字体或inspector宽度。新after与独立复核通过前不计完成。
- [候选回执](contracts/candidate-push-receipt.log)与[after排队回执](contracts/queue-after.log)分开保留；排队/live不是终结证明。新after须核对同一作业的`.done`及末行`exit=0`后回收，不因观察延迟重派。
- Linux portable已10/10，包含radius与localization；缺少Swift SDK，实际WorkbenchChecks只由新Mac gates认证。[回归边界](contracts/regression-observations.md)不把现有截断、固定header字号或未执行关卡写成全面PASS。
- 原始运行产出外部保留，发布PNG不改字节，文本机器路径脱敏；本轮原始失败或未执行项目都分列，不以静态源码替代运行证据。

## 本轮视觉结果与截图索引

- [视觉验证](contracts/visual-validation.md)：before/after共88原PNG，两矩阵各22/22双跑字节一致；11个header场景仅冻结区内改变，其他11场景（含三个preview）RGBA／可见像素均零差异。
- [八组合header对比](comparison/headers-before-after.png)：英文light/dark、默认/放大均恢复完整`Current workspace diff`与`2 files`；中文标题、计数和控件仍完整。
- [英文light全窗口对](comparison/main-english-full-before-after.png)／[英文dark全窗口对](comparison/main-english-dark-full-before-after.png)；派生图原始来源与重采样规则见[provenance](comparison/provenance.json)。
- 主窗口中文原图：[light before](before/main-light/repeat-1/capture.png)／[after](after/main-light/repeat-1/capture.png)，[dark before](before/main-dark/repeat-1/capture.png)／[after](after/main-dark/repeat-1/capture.png)。
- 既有preview原图与每场景双跑索引：[before manifest](before/manifest.json)／[after manifest](after/manifest.json)。九个preview场景（常规八场景加`workbench-empty-light`）全部零差异；Workbench四、Sidebar三、Composer二，与十三个main场景合计22。S03截断仍留队列。
- [后处理诊断伪影](contracts/postprocess-observation.json)：曾误要求持久fixture进程也exit0；实际48个build/screencapture为0、44个fixture主动终止为-15，原manifest不改、不重跑作业。

## 完整契约执行与独立补证

- [Mac gates原日志](contracts/mac-gates/job.log)与[独立本地核验](contracts/mac-gates-verification.json)：生产build、实际Mac WorkbenchChecks、radius/localization、5/5冷启动和正常非捕获态native-design均通过；`.done`与末行`exit=0`存在，checkout前后clean。
- [冷启动结果](contracts/mac-gates/app-launch/result.json)的revision实际为`v0.8.1-313-g4b647966`，完整Git SHA另核；不把两种revision格式混同。native-design真实运行27.70秒、[12张原PNG及布局](contracts/mac-gates/native-design/native-layout.json)已归档。
- Linux portable 10/10，codex-schema实际核对36个bridge方法；运行于产品候选写入后、提交前，HEAD仍是baseline且dirty=true。原件外部保留，不声称clean Linux或已执行Linux WorkbenchChecks。
- [回归边界](contracts/regression-observations.md)：固定header字号、正文18pt代表设置、非全局OS明暗切换、S03既有截断与普通preview人工交互未全认证，分别保留。
- 本轮候选与全部真实GUI测试均为`4b64796633d4cee9db9ac10bbc1ea8b2f4ea4da1`。尚未同轮amend归档；独立复核与归档/远端核验完成后才计轮次，不把报告覆盖层当成重新测试的SHA。
- [原独立复核](review-4.json)保留FAIL和全部九项发现；[逐字处置](review-disposition.md)区分实际gates、数值比较PASS与仍缺的独立目视。四份被原seal保护的说明文档在处置前按原字节保存在[原说明快照](contracts/review-original-authored/)，不改旧seal或原始运行日志。
- [图片能力修复](contracts/reviewer-image-capability-repair.json)仅补指定Kimi模型的`image_in`声明及overrides；同provider/model实际`ReadMediaFile`探针通过，凭据、端点、默认模型与权限不变。这不是独立产品目视验收，缺失覆盖由新独立复核补证。
- [独立目视补证](review-4-image-recheck.json)已实际用`ReadMediaFile`查看八组header、两组完整窗口及对应原PNG；四英文组合完整显示`Current workspace diff`和`2 files`，中文标题与计数完整，未见本轮新增重叠。限定PASS_LIMITED、无新增P1/P2/P3，可与原已通过范围组合闭合有限独立契约；不追改原FAIL或扩大字号／compositor／全局外观／真实会话认证。
- [父代理接收核验](contracts/review-acceptance.json)确认新seal2801份输入在归档前全部不变，原评审、补证JSON、原seal及所有PNG保留原字节；五份将更新的说明先保存在[补证时说明快照](contracts/recheck-original-authored/)，与新seal逐一匹配。
- 原补证保留三个已修正校验伪影（symlink摘要语义、说明文件路径、整行／原摘录误判），均无输入修改；2026-11-19 00:16目标paused时只收取结果，10:19现场恢复active后才推进归档，不将暂停时状态写成持续运行。
- [首次归档／远端核验](contracts/archive-phase-1-verification.json)实际头为`d05f6a4c5e39dd26ce0e80996b7eb73ebf10a767`，正常pre-commit／pre-push通过；源码／Tests／scripts／CI／Package相对真实测试头零diff后才写[完成计数](contracts/round-completion.json)：17→16。最终同轮计数归档头用`git log -1 --format=%H -- docs/design/20x-style-rounds/round-4/contracts/round-completion.json`及外部handoff核实，不自引用或冒充重新运行的GUI证据。
- [归档操作伪影](contracts/archival-operational-observations.json)保留本任务Python缓存造成的一次发布路径finding及原负回执；只清理该自生成缓存，后续`python3 -B`／禁写字节码验证通过，旧产物／用户资产不清理。

## Seal 发布字节与安全门禁

- 首次归档commit被Gitleaks拒绝：两份原seal中十个路径→SHA256条目触发`generic-api-key`。已逐条核对值正好等于被冻结源码的64位十六进制SHA256，无凭据；原拒绝不是生产build／GUI失败，原seal和原评审未改。
- 分支发布两份无损明文副本：[原复核seal](contracts/review-input-sha256-publication.json)／[目视补证seal](contracts/review-image-input-sha256-publication.json)。只把原map改成有序`file`／`sha256`记录；所有原字段、路径、摘要均保留，精确原字节SHA256仍为`60f0e938…`／`8ce41000…`。两份未提交原seal继续在本地及外部原件目录保留，不压缩／编码隐藏数据，也不修改seal假通过。
- [复原校验器](contracts/verify-review-seal-publication.py)绑定原独立评审摘要，默认验证精确原字节；在新检出需解析原评审引用的旧路径时，显式执行`python3 -B docs/design/20x-style-rounds/round-4/contracts/verify-review-seal-publication.py --restore-dir docs/design/20x-style-rounds/round-4/contracts`。已有原件只核对、不覆写；复原原件是运行证据，分支提交的是等价发布副本。
- [严格scanner控制](contracts/seal-publication-validation.json)实际采用相同默认规则、空ignore与`--ignore-gitleaks-allow`：原seal十个误报、发布副本0；合成GitHub密钥及发布副本加该密钥均仍被拒绝。安全／CI脚本、hook、配置、规则和权限均零修改，不通过例外或绕过门禁推进。
