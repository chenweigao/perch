# Round 4 独立复核逐字处置

日期：2026-11-18；归档接续：2026-11-19。原复核为[review-4.json](review-4.json)，SHA256 `91f8ff0b5e89c86f4793abe0c32e02d40f2446bb334ab5d7a25d123d85be261c`；原FAIL、原seal字节、运行日志、PNG及历史评审均不改写。[2791份输入seal发布副本](contracts/review-input-sha256-publication.json)可逐字节复原原seal，原摘要不变。以下每条「原文」逐字保留其`finding_verbatim`，处置不作审美裁决。

原独立目视覆盖阻断已由[新补证](review-4-image-recheck.json)实际独立看图闭合，限定PASS_LIMITED、无新增P1/P2/P3；原FAIL不追改。[首次同轮归档／远端核验](contracts/archive-phase-1-verification.json)通过后[计完成](contracts/round-completion.json)，距汇报16轮；最终计数提交精确核验后才启动S03，不把父代理观察或能力声明当成独立图片验收。真实测试头仍`4b64796633d4cee9db9ac10bbc1ea8b2f4ea4da1`。

## S02-R4-F01 · P2 · 独立目视覆盖

原文：

> 当前评审模型缺少 image_in，图片读取明确被能力限制拒绝；八组 header 和两张全窗口对的独立目视没有执行。原 PNG、像素、来源与预写区域已全部独立核验，但这些结果、源码字符串及父代理的既有目视说明都不能替代本次必需的独立 rendered-text 完整性与无重叠认证。完整独立复核因此 FAIL；这是评审覆盖阻断，不是已观察到产品标题失败，不推翻实际像素或 Mac gates PASS。

处置：定位到本机Kimi 2.5.3中指定模型及其overrides的能力声明均遗漏`image_in`。仅补这一能力，两处声明一致；provider、模型、最高thinking=max、默认模型、端点、凭据及权限策略未变。同模型实际图片探针已通过：`ReadMediaFile`返回image_url，模型准确辨识白底及四区域的形状、颜色、数量；[能力修复回执](contracts/reviewer-image-capability-repair.json)保留初次误用文本Read的失败观察与新探针真实结果。这只验证图片链路，不是S02验收。新任务唯一写入`review-4-image-recheck.json`，实际独立看图PASS_LIMITED，与原已通过范围组合闭合有限契约；不重派原任务、不换provider/model、不改原FAIL、不由父代理代签。

## S02-R4-F02 · P3 · preview 场景分类

原文：

> 独立按现有 driver、wrapper、实际 manifest 和全部原 PNG 枚举为 main 13、Workbench 4、Sidebar 3、Composer 2，共22场景；preview 实际是常规8场景加 workbench-empty-light 1场景，共9。说明写为8而未明确另列该既有 preview 空态，回归文句的总数分类少算1。实际88原 PNG没有缺场景、重复冒充覆盖或允许区扩面，所有9个preview场景均零差异；这是说明分类不一致，不是视觉阻断。

处置：修正README、visual-validation与regression-observations的分类为main13、preview9（Workbench4／Sidebar3／Composer2），明确包含既有`workbench-empty-light`。原manifest、PNG、矩阵比较及冻结允许区不变；旧说明原字节另存，不抹除原分类错误。

## S02-R4-F03 · P3 · Mac gates 过时措辞

原文：

> visual-validation.md 末段仍称 Mac gates 尚未完成，而 style-r4-gates-v1 实际21:54:34终结、有.done、末行exit=0，生产build、WorkbenchChecks、5/5冷启动和正常native-design真实执行通过。该过时措辞与同轮 README、回归结果和原日志不一致；应采用实际终结证据，不据此把 Mac gates 写为 NOT_RUN，也不把 gate PASS当成尚缺目视的独立复核 PASS。本轮未计完成的状态保持正确。

处置：visual-validation末段改为2026-11-18 21:54:34（+08:00）Mac gates实际PASS并链接终结核验，同时明确完整独立目视仍缺失、本轮未计完成。README、回归说明与INDEX仅更新已收取原评审的状态；不重跑已经终结的GUI作业，不改原日志。

## S02-R4-F04 · P3 · 固定字号与机位边界

原文：

> 放大主窗口 fixture 的 .xxxLarge 声明和正文18pt路径均核对，但 header 标题固定14pt、计数固定12pt、外层字体14pt。默认/放大同语言外观的 header 裁剪像素相同符合该固定字号契约，不认证全应用18pt、任意 Dynamic Type、inspector 宽度或更多文件计数。3x nearest 是观察放大，不是3x backing-scale运行；实际机位为1536x900、scale1。

处置：保留固定14pt标题／12pt计数、正文18pt与`.xxxLarge`代表fixture、1536×900及scale1边界。新目视复核也仅认证八个已采集代表组合；3×nearest只作查看，不冒充3×运行、任意宽度或更多计数覆盖。

## S02-R4-F05 · P3 · 外观与 compositor 边界

原文：

> 系统外观策略和 Settings 覆盖源码零diff；正常非捕获态 native-design 真实运行27.70秒并执行显式 app light/dark preconditions。未做全局 OS 明暗切换，不认证所有普通 preview 人工交互。其12张原图为 view-cache PNG，布局 scope明确排除窗口服务器合成 Liquid Glass，不能当成完整 compositor 光学验收。全部运行是离线合成 runtime，不是实际 SSH、真实 Agent、用户会话、权限或性能认证；已裁决玻璃/sidebar/inspector方向不重开。

处置：保留真实native-design执行与静态系统策略证据的分界，不新增全局OS操作、不扩大普通preview人工交互、compositor、真实连接或性能认证。用户已裁决的玻璃、sidebar、inspector方向及默认light fixture不动。

## S02-R4-F06 · P3 · Linux 运行身份

原文：

> Linux portable 10/10、codex-schema36方法有实际日志；运行在候选单行写入后、commit前，日志身份仍baseline aad604b9且dirty=true，不是clean 4b647966测试。source-scope候选hash f7009912…与当前源码及候选提交中保留的该产物吻合；不由dirty布尔值重建当时全部文件清单。Linux没有Swift，WorkbenchChecks未运行；实际认证来自新Mac gates，不能用portable或Mac结果冒充Linux Swift执行。

处置：保留Linux baseline／dirty运行身份、portable10/10与schema36的真实结果，Linux WorkbenchChecks仍NOT_RUN；Mac WorkbenchChecks单列实际PASS。不改manifest、不由源码hash或dirty标志反推完整历史checkout，不把归档头写成重新测试头。

## S02-R4-F07 · P3 · 持久 fixture 退出伪影

原文：

> 后处理初次aggregate exit1及错误断言保留；实际每矩阵92命令为4build+44screencapture共48个exit0，以及44个ready/截图后由既有driver主动SIGTERM的持久fixture，记录-15。原manifest、driver和截图不改、不重跑。该诊断是错误要求fixture也exit0，不是capture FAIL或正常native-design退出失败。初始完整postprocess traceback未出现在本次读取的日志输入中，初始错误回执按postprocess-observation保留；退出分类及因果已独立核对原manifest和driver。

处置：原负回执、48个exit0／44个-15分类及未读取完整初始traceback的局限保留。只读原manifest／driver，不把全部92个退出改写为0，不把主动fixture结束说成GUI截图失败或native-design退出故障。

## S02-R4-F08 · P3 · 发布与空白负回执

原文：

> 初次publication11个personal-path findings来自两份portable文本：bridge.log1个、results.json10个；本次对外部原件实算逐条与负回执吻合。发布副本只替换HOME前缀后为0，负回执和原件保留，不能抹成初次PASS。原编译日志/diff尾随空格保留；分阶段3+2正好五个原证据路径排除，其余authored/staged whitespace实际通过，完整未排除检查仍exit2。发布的负诊断摘要仅省去两行重复编译上下文，完整外部诊断核对保留。模式0 findings不认证图片隐私、未知凭据、授权或许可；历史5942全仓库扫描没有由本代理重跑。

处置：保留11个personal-path负回执及外部原件、五个精确原证据空白排除，不扩大排除或清理原日志。新增发布文档独立扫描，0 findings仅表示已配置模式通过，不代表未知凭据、图片隐私或许可全面认证。

## S02-R4-F09 · P3 · 历史、S03与轮次计数

原文：

> Workbench-english原PNG及其他清单外场景与before字节/像素相同；S03筛选器既有截断仍留队列，本次未独立目视其文字，也不宣布全产品无截断。round2维持撤回、视觉FAIL、完整契约NOT_PASSED，不复活候选或改历史评审；round3已完成并归档aad604b9，其旧五项边界及真实测试头025dc61c保持。round4尚未计完成，真实测试/当前HEAD仍4b647966，距汇报17，不把待amend本地证据覆盖层说成parent checkout clean或已重新测试归档头。

处置：round2撤回／视觉FAIL／完整契约NOT_PASSED和round3真实测试头及限定PASS保持。S03仍待执行；本轮补证与首次同轮归档／精确远端核验实际通过后才计17→16，见完成回执。原评审时17轮身份不追改，不称parent checkout clean，不重跑旧候选或混淆测试头与归档头。

## 原输入保护与说明变更

- 原seal及review-4.json独立hash不变；处置开始前已重验全部2791份输入零失配。
- 只允许四份原保护说明变更：本轮README、contracts/visual-validation.md、contracts/regression-observations.md与INDEX。其原字节保存在[review-original-authored](contracts/review-original-authored/)，对应原seal摘要可重新核对；外部原件另留存。
- 产品、Scripts、Tests、CI、Package与旧轮证据不变；新补证使用另一个seal，绝不重写原seal让历史校验假通过。
- 首次说明patch已修改README后，在visual-validation的整段原行匹配失败；检查明确其余三份未变，随后按实际整段匹配完成。该编辑伪影不是运行或产品失败。
- 新独立补证后，原2801份输入已再次全部核验不变；归档更新五份说明之前保存[补证时说明快照](contracts/recheck-original-authored/)，原新seal、补证JSON及原评审不改。三个补证校验伪影及父代理一次jq字段类型误判保留在原JSON／[接收回执](contracts/review-acceptance.json)，不冒充产品或运行失败。
- 归档pre-commit被十个源码SHA256误报阻断，原拒绝及严格scanner控制见[发布格式验证](contracts/seal-publication-validation.json)。只将新发布副本的路径→摘要map表示为明文file／sha256记录，原字段、顺序、全部摘要不变且能复原精确原字节；原两份尚未提交的seal留在本地及外部原件目录，不覆写。分支提交无损发布副本与复原校验器；原评审路径可按README命令复原。无allowlist、hook／规则／脚本／权限变动，合成密钥阳性控制仍被拦截。
