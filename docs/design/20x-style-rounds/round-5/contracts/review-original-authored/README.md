# Style loop round 5：既有 Workbench 筛选器宽度契约

日期：2026-11-19。队列项：S03。状态：新before／after的27场景、19项控制、portable、实际目视与完整Mac gates通过；候选`0b05897b`已精确推送，准备独立复核，本轮未计完成，距汇报16轮。

## 基线与边界

- round4最终归档／精确远端头`566c0c3e449fa076adbee1d91a9002ddd561034d`已核实；真实S02测试头仍`4b647966`，原FAIL与新目视PASS_LIMITED及全部认证边界保留。
- 本轮开始重新fetch main／style；main仍`65cf2fc67623a916f12797371d1ca087c911b24f`，已在style分支内，无新增merge或冲突。性能INDEX明确用户于2026-11-18确认结束；Mac runner现场存活、队列空、shared checkout clean。
- 只取S03既有Workbench preview筛选器：旧图确认中英任务组当前值都截断，英文机器值截断。先采新before确认；不把旧图当成本轮交付截图。
- [预写差异](expected-differences.md)与[允许区](allowed-regions-before.json)先于本轮GUI和产品修改写入。唯一假设是在原生Picker保留完整当前值的水平固有宽度，原最小宽度保留，不藏标签或缩字。

## 新作业与三层契约

- 新before名称`style-r5-before-v1`；新support`style-r5-support-v1`，不重派任何round4作业。
- 同一冻结wrapper沿用既有capture driver，只把已有Workbench的PREVIEW_VARIANTS补到八组合；main十三、Workbench九（含既有empty）、Sidebar三、Composer二，共27场景／各双跑。
- 契约层：Linux portable；Mac实际WorkbenchChecks、radius／localization、三个既有preview构建、生产build、5/5冷启动及正常非捕获态native-design。
- 视觉层：before／after各54原PNG，重复27/27字节一致；冻结header区域之外RGBA／可见像素零差异；九个Workbench中英／字号／明暗代表图独立查看当前值与无重叠。
- 回归层：系统外观与Settings策略源码不变，默认fixture light；不宣称全局OS切换、所有原生字18pt、任意宽度／计数、完整compositor或真实连接／权限／性能认证。

GUI／build全部只通过PerfRunner，使用离线synthetic fixture bundle；SSH只部署或短查询。before通过前不改产品，after及新独立复核／同轮归档完成前不计本轮。

原round2撤回、视觉FAIL／完整契约NOT_PASSED不改判；其他Sources、WorkbenchCore、测量／CI脚本语义零diff。无PR／向main合并请求。

## 本轮实际接续

- 同一`style-r5-before-v1`于10:59:27终结，`.done`存在、日志末行`exit=0`、队列文件已移除；27场景449.714秒，前后shared checkout均clean。不重派。
- 54原PNG已回收；原件及发布副本均27/27重复字节、RGBA／可见像素、机位／fixture一致；文本只脱敏机器home前缀，PNG原字节不变。证据见[before原件验证](contracts/before-original-validation.json)、[发布验证](contracts/before-publication-validation.json)和[原图索引](before/manifest.json)。
- 九组header和英文完整窗口已实际目视：中英任务组值截断、英文机器值截断；中文机器值原已完整。预览状态的中文标签及首次使用值截断是已有现象，本轮不改文字／字体或硬130pt。
- 比较器沿用受hash保护的round3 PNG解码语义，重新实现27场景精确覆盖和双通道零容差；冻结契约、清单、允许区、wrapper与driver均绑定hash。[19项合成控制](contracts/comparer-controls.json)通过，包含隐形RGBA、半开边界、字节漂移、hash／机位／场景缺失及冻结输入篡改；合成输入不是交付截图。
- 唯一产品变更为既有Workbench preview的任务组／机器Picker添加水平`fixedSize`，原130／120改`minWidth`；bindings、内容、预览状态Picker、10pt间距、字体、padding、主窗口与dashboard不动。新after必须证明九场景header外及其余十八场景零差异，失败不扩大预写区。
- Linux portable实际10/10、15.53秒，运行在两行产品写入后／提交前，HEAD仍为baseline且dirty=true；[源范围与hash](contracts/source-scope.json)、[结果](contracts/linux-portable/results.json)和未改原件另存。Linux无Swift SDK，WorkbenchChecks未执行，必须由新Mac gates认证。
- 候选全量`git diff --check`实际发现两处原编译诊断行尾空白；原件和发布证据保留，不修剪日志冒充全量PASS。只精确排除这两份原日志后的产品／其他报告检查通过，见[归档边界](contracts/archive-validation.json)；正常commit／push安全hook不绕过。
- 一个conventional候选头`0b05897bad0dfaa22aef446422bbd3a5c31f92ea`已提交。首次push发生真实TLS断连、exit1，不采信其`Everything up-to-date`尾句；短查询确认远端仍baseline，随后同一SHA正常显式重推成功，11:19:29精确核验远端，Mac独立查询也一致。hook／scanner／TLS／credentials／权限配置均未改，原失败与成功日志保留在[candidate publication](contracts/candidate-publication/)。
- 唯一新`style-r5-after-v1`于11:21:58原子入队，预检runner存活、队列0、shared checkout clean；[入队回执](contracts/candidate-publication/queue-after.log)仅表示queued，不认证终结或视觉PASS。继续观察同一作业，gates只能在新after区域比较和目视通过后入队。

## 三层证据：当前实际结果

- [视觉验证](contracts/visual-validation.md)及[原件区域比较](contracts/after-original-region-check.json)／[发布区域比较](contracts/after-region-check.json)全部PASS。九个WB header仅原冻结区内变化，其余十八场景全窗口RGBA／visible零差异；前后各27/27双跑字节一致，共108原PNG。
- [九组合header before／after](comparison/headers.png)，[英文light全窗口](comparison/workbench-english-full.png)／[dark全窗口](comparison/workbench-english-dark-full.png)已实际查看。两项当前值中英完整，无新重叠；[派生来源](comparison/provenance.json)绑定原PNG、3×nearest裁剪及全窗口无缩放。
- 主窗口原图对：[light before](before/main-light/repeat-1/capture.png)／[after](after/main-light/repeat-1/capture.png)，[dark before](before/main-dark/repeat-1/capture.png)／[after](after/main-dark/repeat-1/capture.png)。十三main场景及Sidebar／Composer均零差异；不把未改区域的零差异说成全局OS／权限／性能认证。
- 回归策略与未认证边界见[阶段观察](contracts/regression-observations.md)，其“尚未执行”保留为当时事实；此后实际Mac gates与独立结果另列，完成前不计数。
- 新`style-r5-gates-v1`11:42:31入队，11:45:03终结exit0；[实际验证](contracts/gates-validation.json)、[完整日志](contracts/mac-gates/style-r5-gates-v1.log)与[原生布局](contracts/mac-gates/native-design/native-layout.json)已回收。production build、实际WorkbenchChecks、radius／localization、5/5冷启动、正常非capture native-design全部通过，12原PNG原字节保留。
- [冷启动](contracts/mac-gates/app-launch/result.json)的实际revision为`v0.8.1-314-g0b05897b`，完整GUI测试头另为`0b05897bad0dfaa22aef446422bbd3a5c31f92ea`，不混同。其余十八场景不仅RGBA／visible零差异，跨作业PNG字节也实际相同；本轮共120原PNG（108矩阵＋12正常native-design）。
- 当前仍待独立复核／发现逐字处置／同轮归档及精确远端核验，不提前计完成。原round2视觉FAIL、完整契约NOT_PASSED与round4历史FAIL／后续限定目视补证均不改判。

## 后续候选，不在本轮扩面

- 本轮前后都观察到既有预览状态`首次使用`仍截为`首…`，与任务组／机器宽度同类，但S03预写边界明确保持该Picker不变。已将单独的S09宽度契约候选入INDEX；须本轮收尾后新baseline／新清单／新评审，不改当前两行产品或冻结区。
