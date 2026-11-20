# Round 8 / I02：窄窗截图稳定性基建

状态：**FAIL_INFRA／完整契约NOT_PASSED**。本线程截图源码已恢复；独立停止处置复核已完成，限定结论PASS_LIMITED，不代表链路恢复。`completed_round_delta=0`，距20轮汇报仍14轮。

几何初候选`91711d43`的v1原作业12:38:29实际exit1：构建／定尺寸通过，但两PNG字节不同；原35文件验证一致，RGBA383／visible381／alpha7变化，正常gates／8组合／34矩阵均NOT_RUN。原FAIL不改。修改前固定5秒唯一补证v2于12:55:00原exit0，21原文件／2PNG核验一致；限定中文light14pt两独立进程PNG字节／RGBA／visible／alpha全0，不认证完整链路或根因。

此前将限定pilot通过的纯截图等待逐字落实为最终候选；以下假设保留为当时预写契约。最终候选现已真实失败，不继续剩余GUI、不改v1／旧685像素／round7原判，也不询问逐步继续。

## v3 实际失败与停止

- 最终候选`0e2758ecffef5964d99c3d833e0b1535468a59d5`经同轮amend与精确lease显式push实际exit0，仍只有一条round8提交。新且唯一作业`style-r8-capture-gates-20261120-v3`于2026-11-20 13:12:45入队，13:14:02原`body_exit=1`、runner `exit=1`；13:17:58短查得到已终结原回执，未重派。
- 13:22:15父代理核验原tar `db6230aecef7b38316532c832255da54654389e1758aa9f294cdc2d1142ed398`、35原文件及两完整PNG；507份源码摘要与原计划一致。旧尺寸负控制预期exit1、新host目标构建exit0、窄窗pilot实际exit1。回收传输与数值验证器exit0仅认证回收／实算，不替代原作业exit1。
- 两次均为836×900、原点[48,72]、中文light14pt，同一ready metadata与固定5秒等待；PNG字节不同，**RGBA200／整数白底visible200／alpha0**，bbox `[5,4,831,889)`。原PNG已实际目视，未见明显新叠字；既有sidebar遮挡仍在，不能靠目视替代零容差失败，也不认证根因。
- 八组合、正常11gates、5冷启动、三既有preview构建和普通34场景矩阵均**NOT_RUN**：pilot失败后原作业即退出；不将旧功能v2／旧34矩阵PASS冒充本轮通过。
- 原v1 FAIL、v2仅中文light14pt的限定pilot PASS、旧685像素NOT_PASSED、round7 FAIL／NOT_PASSED／NOT_RUN全部保持。未调容差、掩膜、挑帧、改玻璃、fixture或正常验收；没有v4或新审美轮。
- 按原停止规则②落实基建阻塞。13:23:34本线程恢复helper原字节并移除新增活动截图脚本，`git diff 829ba3a9 -- Sources Tests scripts`实测为空；候选源码逐字保留，10,865旧输入保护通过、physical index未变。本地恢复不代表Mac源码或运行程序已恢复；Mac完整gates仍NOT_RUN。
- GUI兜底已停用；唯一已排的本线程GUI定时续作`ordinal:34`已取消，防止终结后的过时GUI阶段再触发。唯一独立停止复核已完成；只收尾同轮回滚归档，不继续S04/S05、不重派复核或作业。

## 假设与写集

复用既有静态截图 fixture 与 ready 信号，通过截图专用 helper 的 opt-in 进程内内容尺寸固定 836×900，不再在正常动态验收的短暂窄窗阶段抢拍。仅改 `Tests/HostLifecycleChecks/StyleCapture.swift` 的截图尺寸入口和新增 `scripts/capture-style-loop-narrow.py`；正常功能验收断言／测量／CI、Sources 和产品外观零改动。

预写差异清单：[EXPECTED.md](EXPECTED.md)。外部 AX 改窗路径的只读探测为 false，已放弃该路径，没有请求权限、改 TCC 或执行 GUI。

## 三层证据

- 契约层：本地8项mock控制与portable10/10实际通过，固定等待候选13:09:26重验portable通过、包含radius／localization；Linux无Swift，不记WorkbenchChecks PASS。v1与v3只有Mac目标构建通过；完整正常gates均NOT_RUN，不借用旧通过。
- 视觉层：v1、v2、v3各两张完整窄窗原PNG分别保留，v1 FAIL／v2限定pilot PASS／v3 FAIL；新八组合与普通矩阵NOT_RUN。旧685像素失败与旧review不改。
- 回归层：本轮仅中文light14pt实际窄窗截图；中英八组合／18pt／dark／正常外观与fixture功能断言均未完成，不认证遮挡修复或完整回归。

## 独立复核与归档

[review-8.json](review-8.json) 已实际交付并读取，SHA256 `cb09432c3436e3bbd50781f3e82ad221cdf09de19fde995cf181eb4907e7b92b`。结论PASS_LIMITED仅认证失败证据、本地恢复及停止处置；P1×1、P2×3、P3×1全部见[逐字处置](review-disposition.md)。原六PNG均独立原生分辨率目视及实算，91原件、220来源记录、四历史锚点核验。指定provider/model的请求与配置为`thinking=max`／`mode=default`，实际执行仍UNVERIFIED；不由配置扩大认证。

父代理13:56:41接收核验11,384项冻结输入、seal自身、候选HEAD与physical index均不变。只在复核后按授权更新四份说明并收尾同轮回滚归档；旧说明、原review及候选源码字节另存，其余证据不改。原独立scanner最终225文件／0 findings／exit0只认证当时范围，后续新增处置与归档另实扫。最终归档SHA以Git及外部`style-loop-stop-finalization-20261120/final-head-v1.json`实际回执为准，不与取证候选`0e2758ec`混同。

本轮失败未计完成；停止证据与源码恢复归档不等于功能或视觉PASS。不恢复审美，不开启S04/S05，不合并／开PR。全部轮次与六截图索引见[停止总结](../../20x-style-loop/STOP-20261120-R8.md)。

## 前置负回执

旧窄窗诊断 guard 固定要求 Tests 零改动，拒绝本轮已预声明截图 helper 修改；原 validator 不改，以独立旧输入校验核对10,865项，只有预声明 helper 与三份说明变化。全仓 public-source 扫描120秒超时，wrapper exit124、底层 process_exit=null，不记 repo PASS；按实际发布的四份候选文件做源摘要固定的独立 snapshot 扫描，原超时回执保留。

父代理13:10:19外层末行检查误取提交消息尾部空行而exit1，stage／commit／push未执行；原规定尾注完整存在，纠正为rstrip后检查。v3原件验证器初版已核验35文件后误用`plan-original-v3.json`，实际复用副本名仍为`plan-original-v1.json`；原初版保留，v2只修读路径并逐字重验已提取文件，不改原件。两项工具负回执与原GUI FAIL分开归档。

最终归档暂存的git实际exit0；随后路径断言因默认R100将删除脚本显示成归档目录内的移动而失败。用`--no-renames`只重新核对真实写集，确认232项仅属授权路径、源码暂存对`829ba3a9`零diff；没有再次stage、commit、GUI或改原件。原断言错误保留，外层工具最终exit0不冒充该断言成功。非原始证据的暂存空白检查通过，原证据字节不为格式检查改写。

2026-11-20 14:04:40全仓原scanner实际exit0、9446文件／0 findings，只认证该次范围；旧120秒timeout124与先前9441范围保持。随后补写本段及归档验证说明的最终目录snapshot另实际执行，回执在外部`style-loop-stop-finalization-20261120/receipts/`，不由旧扫描扩大认证。

首次同轮commit于14:07:29被未修改的安全hook实际exit1拦下，HEAD未变；24个generic-api-key finding经逐项核对都是固定Git源码SHA256，分布在六份公开source_hashes映射。按[公开衍生overlay](contracts/security-publication-overlay-v1.json)，仅将这六公开副本的3042个摘要无损改为JSON字节数组，私有执行计划／原件、旧公开副本、220来源记录和原review保持。解码及逆向逐字恢复通过；其余11,374项保护输入不变，四份说明与六衍生另列，不追改原11,380阶段回执。未修改／跳过安全hook或allowlist，修正后由真实hook再验。

衍生工具初版因patch单参数超过系统限制在apply_patch执行前exit1；仅第一份原副本已保存，没有发布文件修改。修正为stdin输入并核验已有副本，原代码与负回执保留。此工具负回执不改变GUI FAIL、commit hook FAIL或截图零容差。

后续补暂存显式列出已在index删除的脚本路径而exit128；删除早已正确暂存，并非源码恢复失败。只补暂存仍存在的本轮路径，保留原负回执，不撤销index、不重建脚本、不运行GUI。
