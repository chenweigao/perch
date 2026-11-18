# Style loop round 4：inspector 标题宽度契约修复

日期：2026-11-18。队列项：S02。状态：真实测试头`4b647966`的三层证据已齐备，新Mac gates于21:54:34实际PASS；独立复核尚未收取，本轮未计完成，距汇报仍17轮。

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
- 既有preview原图与每场景双跑索引：[before manifest](before/manifest.json)／[after manifest](after/manifest.json)。八个preview场景全部零差异，S03截断仍留队列。
- [后处理诊断伪影](contracts/postprocess-observation.json)：曾误要求持久fixture进程也exit0；实际48个build/screencapture为0、44个fixture主动终止为-15，原manifest不改、不重跑作业。

## 完整契约执行与待归档状态

- [Mac gates原日志](contracts/mac-gates/job.log)与[独立本地核验](contracts/mac-gates-verification.json)：生产build、实际Mac WorkbenchChecks、radius/localization、5/5冷启动和正常非捕获态native-design均通过；`.done`与末行`exit=0`存在，checkout前后clean。
- [冷启动结果](contracts/mac-gates/app-launch/result.json)的revision实际为`v0.8.1-313-g4b647966`，完整Git SHA另核；不把两种revision格式混同。native-design真实运行27.70秒、[12张原PNG及布局](contracts/mac-gates/native-design/native-layout.json)已归档。
- Linux portable 10/10，codex-schema实际核对36个bridge方法；运行于产品候选写入后、提交前，HEAD仍是baseline且dirty=true。原件外部保留，不声称clean Linux或已执行Linux WorkbenchChecks。
- [回归边界](contracts/regression-observations.md)：固定header字号、正文18pt代表设置、非全局OS明暗切换、S03既有截断与普通preview人工交互未全认证，分别保留。
- 本轮候选与全部真实GUI测试均为`4b64796633d4cee9db9ac10bbc1ea8b2f4ea4da1`。尚未同轮amend归档；独立复核与归档/远端核验完成后才计轮次，不把报告覆盖层当成重新测试的SHA。
