# Style loop round 6：既有预览状态当前值宽度契约

日期：2026-11-19。队列项：S09。状态：新 before／after 各 34 场景／68 原 PNG、双跑一致及冻结区外双通道零差异通过；首次使用八组合恢复完整，日常八组合及主窗口代表图目视通过。一行产品、Linux portable 10/10、完整 Mac gates 及原件／发布副本消费均通过，真实候选 `7e66eb2e` 不改。独立评审 PASS_LIMITED、无 P1/P2，唯一非阻断 P3 已逐字处置；首次同轮归档、精确远端与源码保护核验通过后计完成，距汇报还剩 14 轮。最终同轮计数归档头以 Git／外部 handoff 核实，不冒称重新运行 GUI。

## 基线与单一假设

- round 5 完成归档头 `2ded248b7f3d6993841b05c88b33f36add451a92` 已核实本地／远端；真实 S03 GUI 测试头仍 `0b05897b`，120 原 PNG、有限独立 PASS_LIMITED、唯一 P3 逐字处置和 16→15 计数均已归档，不重做。
- 本轮重新 fetch origin main／style；main 仍 `65cf2fc67623a916f12797371d1ca087c911b24f`，已包含，无 merge 或冲突。性能循环 INDEX 记录用户于 2026-11-18 确认结束；GUI 仍只通过串行 PerfRunner，不直接在 SSH 内构建／操作窗口。
- S09 来自 round 5 前后同机位观察：预览状态的 `首次使用` 仍为 `首…`。只给该原生 Picker 水平固有宽度，原 130pt 改为最小宽度；不改字符串、tags、binding、选项／默认状态、字体、10pt 间距、S03 两项 Picker、主窗口或其他区域。
- [预写差异](expected-differences.md)与[固定允许区](allowed-regions-before.json)先于新 GUI 和产品修改写入；不拿旧图代替新 before，不在看到 after 后扩大允许区。

## 三层证据与新矩阵

- 原有主窗口十三场景、Sidebar 三场景、Composer 两场景不变；既有 Workbench 页面日常八组合＋首次使用八组合，中英×默认／xxxLarge×light／dark，共 34 场景，每矩阵 68 原 PNG／34 双跑。
- [本轮 wrapper](contracts/capture-matrix.py)复用原 `scripts/capture-style-loop.py` 的构建、机位、清偏好、ready／screencapture、像素与重复流程。只在载入内存源码时将唯一日常场景参数行扩展为受显式 fixture 标记控制的首次使用；原文件字节不改。新增七组首次使用组合，保留原 empty-light。实际命令与环境必须在 manifest 证明 `-scenario 首次使用`，不是仅重命名截图。
- 契约层：Linux portable，Mac WorkbenchChecks、radius／localization、三个既有 preview build、production build、5/5 冷启动、正常非 capture native-design。Linux 无 Swift，不将 WorkbenchChecks 未执行记为 PASS。
- 视觉层：十六个 Workbench header 只允许原比例半开 `[480,48,1112,104)`；其他十八场景全窗口 RGBA／白底可见像素及 PNG 字节必须零差异。每个矩阵双跑字节一致、机位／fixture 一致；清单外差异回滚本轮，不扩面。
- 回归层：首次使用八组合及日常八组合实际查看完整当前值、标签与无新增重叠；另保留主窗口 light／dark 和正常 native-design。系统跟随源码及默认 light 不变，不宣称全局 OS 切换、任意菜单值／窗口、全应用 18pt、真实连接／权限、性能或完整 compositor 光学认证。

## 作业与保留边界

- 唯一新 before 名称 `style-r6-before-v1`，support 为 `style-r6-support-v1`；不重派任何已完成 round 0–5 作业。before 通过前不改产品；after、完整 gates、独立评审及同轮归档通过前不计完成。
- 初始只读 Mac 预检在默认 zsh 下遇空队列 glob 的 `no matches found`，exit 1；显式 bash 的第二次读取又遇 Bash 3.2／nounset 的空数组展开错误，exit 1。二者均未到共享工作树检查、未启动 GUI。第三次以 nullglob／非数组计数核验 PASS，runner PID 69667 存活、队列 0、共享 checkout clean、HEAD 为旧真实测试头 0b05897b，所有 r6 名称未使用。原负回执保留于[预检证据](contracts/mac-preflight/)，不改全局 shell／配置，不把命令调用错误当 PerfRunner 故障。
- 原 round 2 撤回、视觉 FAIL／完整契约 NOT_PASSED，round 4 原 FAIL／后续有限目视 PASS_LIMITED，以及各轮未认证边界不改判。WorkbenchCore、其他 Sources、测量／CI 语义保持零 diff；不开 PR、不合 main、不碰真实数据／SSH 凭据或权限。

## 实际接续

- 同一新 `style-r6-before-v1` 于 14:33:49 原子入队；job SHA256 为 `a0c99ffd02e120f180aa5ed959e4fbd9a94fedcef8ff4873762f2cd7cfe87400`。预检 runner 存活、队列 0、共享 checkout clean；[入队回执](contracts/before-enqueue/queue-before.log)本身只认证 queued。
- 14:36:49 短查询确认该作业 PID 8753、同一 capture 进程 PID 8828 及 HostLifecycleChecks 子进程实际存活，代码头已 checkout 到真实新基线 `2ded248b`、hash 断言通过；当时未 terminal。见[真实进程观察](contracts/before-enqueue/before-observation-1.log)。继续查同一 `.done`／末行 `exit=N`，不因等待重派。
- [14 项控制](contracts/pixel-and-frozen-controls.json)全部 PASS，包含半开四边、隐形 RGBA、stability 零差异及六种冻结输入篡改拒绝；原输入不变。合成输入仅外部保存，不作交付截图。34 场景完整 CLI 控制须在新 before 回收后运行。
- after／gates job 已准备并通过 bash 语法校验，均未入队；before、目视和控制通过前不改产品，after 区域比较与实际目视通过前不派 gates。
- 同一 before 于 14:42:21 终结 exit0、497.991 秒，34/34 双跑字节一致；68 原 PNG 与有效明暗／语言／字号／机位已独立验证，前后共享 checkout clean。见[完整 before 验证](contracts/before-validation.md)、[原件 v2](contracts/before-original-validation-v2.json)、[发布验证](contracts/before-publication-validation.json)和[原图索引](before/manifest.json)。
- 原 tar 的 AppleDouble 传输元数据导致初次 consumer PNG 后缀计数失败，原负回执保留；经真实 Mac 文件数与 magic 核对，仅排除非图片传输元数据形成字节不变逻辑视图，不重拍、不更换基线、不改 comparer／允许区。见[归档传输记录](contracts/archive-transport-observations.json)。后续归档采用每命令 `COPYFILE_DISABLE=1`，只抑制打包侧元数据，不改原图或全局配置。
- 首次使用八组合与日常八组合 header 已实际目视，前者全部 `首…`、后者 `日常` 完整；任务组／机器保持 S03 完整当前值。26 项控制全 PASS、345 份原输入未变；原图及[派生来源](baseline-visual/provenance.json)保留。
- 唯一产品变更是 `Tests/WorkbenchPreview/App.swift` 的预览状态 Picker 一行 `fixedSize(horizontal:true, vertical:false) + minWidth130`，[源码范围](contracts/source-scope.json)证明其余 Sources／Tests／scripts／CI／Package 不动；[portable](contracts/linux-portable/results.json)实际10/10，HEAD为baseline、dirty=true、产品已写入；Linux WorkbenchChecks未执行。新after／Mac gates／独立评审通过前不计完成。
- 一个 conventional 候选头 `7e66eb2e5a9dac92eea8d6178e55e7ab5f38e554` 已正常 commit／显式推送，安全 hook 与 push 实际 exit0；首个后续精确查询遇 TLS 失败，原空记录／负回执保留，未独立捕获当次 Git 数字退出码，不补造。普通重查 exit0 核对同一完整 SHA，Mac 入队前独立查询也一致，无重推、TLS／credentials／hook／scanner／权限配置变更。见[候选发布证据](contracts/candidate-publication/)。
- 唯一新 `style-r6-after-v1` 于 15:10:59 原子入队，job SHA256 `45eb5c263fbc7076b8893acd8a4af434db7ebefb4a06ba4c8b34ff53239a7d10`；runner 存活、队列0、共享 before 头 clean，候选与新 before-v2 的前置验证已部署。回执只认证 queued，不提前说 after／gates PASS；继续同一作业，不重派。
- 同一 after 实际于 15:18:56 终结 `exit=0`，capture 463.62 秒、34/34 双跑一致；15:21 的新查询已确认 `.done`、末行及 68 原 PNG，不把旧的 44/68 进度当作当前状态。用每命令 `COPYFILE_DISABLE=1` 打包回收，455 个成员／351 个普通文件、68 真 PNG，无 AppleDouble 排除；原包 SHA256 `85dab0a0c5090942e83049d7357d7464a0967cb1a8648d09fed810b4d27b4e44`，Mac 与本地相同。见[回收验证](contracts/after-archive-validation.json)与[原作业回执](contracts/mac-after/style-r6-after-v1.log)。
- [原件比较](contracts/before-after-original-comparison.json)与[发布副本比较](contracts/before-after-comparison.json)均实际 PASS：136 矩阵原 PNG，before／after 各 34/34 双跑字节、RGBA／白底可见像素一致；十六 header 清单外两通道均为零，其余十八场景全窗口零差异且跨作业 PNG 字节相同。未扩大 `[480,48,1112,104)` 或更换 fixture。
- 实际查看两张八组合 header 对、四张首次使用完整窗口对、四张对应 after 原 PNG，以及主窗口 before／after light／dark 四张原图；首次使用全部完整、日常仍完整，S03 两项当前值、箭头、标签及标题无新增重叠。只认证所查看的固定组合，不扩大到任意宽度／所有状态或全应用字号；[派生图来源](comparison/provenance.json)与[目视记录](contracts/visual-validation.json)分开保留。
- 首次本地消费的整体 shell 回执为 141，仅按父代理当时实际工具回执保留：所有归档验证、两次比较、两次发布及派生生成均已写出 PASS 后，作者将最后的 `jq ... | head -n 50` 摘要管线解释为 `pipefail` 下的 SIGPIPE。冻结输入没有原 process 数字退出码与完整末段管线回执，独立评审未重新认证 141 数字或 SIGPIPE 因果；原负回执不改判为整体 shell PASS，也不误归类为 GUI／像素／Mac gates FAIL。随后只用有界 `jq` 读取既有 PASS 报告，不重跑 GUI／消费器。解包另有 Python 3.14 默认过滤的 DeprecationWarning；本次已逐个校验相对路径、无链接／特殊文件及 PNG magic，未隐藏告警、未补造重跑。见[消费边界记录](contracts/after-consumer-observations.md)与[逐字处置](review-disposition.md)。
- 唯一新 gates 于15:28:31原子入队，job SHA256 `eed80c4706ce716b99179767b33ea5ed24eb0e3daa842c6f31cb200e7211f380`；同一作业于15:30:55终结 `exit=0`，实际 production build、WorkbenchChecks、radius／localization、5/5冷启动及正常非capture native-design通过。描述印记 `v0.8.1-315-g7e66eb2e` 与完整测试SHA分开；capture环境已unset，原host binary摘要与after一致，源码与CI红线零diff、共享checkout前后clean。见[原gates](contracts/mac-gates/style-r6-gates-v1.log)。
- 正常native-design的12原PNG完整回收；gates原包39成员／31普通文件，SHA256 `ff27a4b1badd11bf141e73d3fa1ee5b5dbfe6b183491963596f0988d923cc7c7`，逐个安全相对路径与普通文件原字节比对通过。本次实际使用 `filter=data`，不追改旧解包告警。原件与发布副本的[完整gates消费](contracts/gates-publication-validation.json)均实际exit0；本轮共148原PNG，未因归档或脚本验证重跑GUI。
- 独立评审通道在本轮派发前重新查询实时注册表，指定provider／model仍可用且最高thinking仍为max；只对子任务显式default，避免注册表默认yolo，不改全局配置／权限。19条历史finding原对象、原verdict与原source摘要已[固定](contracts/historical-findings.json)，新评审通过与逐字处置／精确归档前仍不计完成。
- 原[独立评审](review-6.json)已完成并收取：PASS_LIMITED，P1 0／P2 0／P3 1；28 次实际独立目视、148 原 PNG 与 34 场景冻结契约通过。唯一 P3 已[逐字处置](review-disposition.md)，原评审及 R6-L01–R6-L17 不改写。两份冻结作者说明先按原字节保存于 [review-original-authored](contracts/review-original-authored/)，随后才修正当前状态；7772 项保护输入及源码由既有 verifier 再验。同轮归档与精确远端／源码核验通过前仍剩 15 轮，不重派评审或 GUI。
- 首归档头 `c0275629df4e50a38e3942dc88d98f3c6006fdb4` 正常 amend／安全 hook 通过。首次 push 实际 process exit1，TLS 断连与误导的 `Everything up-to-date` 尾句原样保留；随后查询实际 exit128，均不包装成功。普通重查确认远端仍为 `7e66eb2e` 后，原同一归档 SHA／精确 lease 正常重推 exit0，精确远端重查 exit0。没有修改 TLS／凭据／hook／scanner／权限配置；[原日志与数字回执](contracts/archive-publication/)保留。
- [首归档再验](contracts/review-first-archive-verification.json)再次核实原评审、7772 项保护输入、19 条历史发现与产品／脚本零 diff 后，才写入[完成记录](contracts/round-completion.json)，计数 15→14。完整 whitespace 实际 exit2，只有四份精确原构建日志例外之外 exit0；[原诊断与例外](contracts/archive-publication/whitespace-validation.json)保留，不修剪原日志、不称全量 PASS。最终计数归档需正常同轮 amend／精确推送与源码核验后才开始 S04；真实 GUI 测试头始终 `7e66eb2e`。
- 最终计数归档新增两份 TLS 负回执和原 whitespace 诊断副本也保留原尾空格；完整检查仍实际 exit2。[计数归档 whitespace 再验](contracts/archive-publication/whitespace-accounting-validation.json)逐字保存新完整诊断及摘要，精确列出七份保留日志，除此之外实际 exit0。没有以删空格、改写原回执或全目录豁免换取全量 PASS。
