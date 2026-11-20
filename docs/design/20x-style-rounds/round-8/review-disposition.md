# Round 8：独立停止复核逐字处置

原 [review-8.json](review-8.json) 的 SHA256 为 `cb09432c3436e3bbd50781f3e82ad221cdf09de19fde995cf181eb4907e7b92b`。父代理于2026-11-20接收完成通知后读取实际JSON；13:56:41复验11,384项冻结输入、seal自身、候选HEAD及physical index均未变，effective Sources／Tests／scripts对`829ba3a9`零diff。原复核不追改。

结论仅为停止处置 **PASS_LIMITED**。视觉 **FAIL**、完整契约 **NOT_PASSED**、正常gates **NOT_RUN**、根因及最高thinking实际执行 **UNVERIFIED**。五项新发现逐字保留；P1及三项P2继续阻止循环恢复，不将归档完成称为契约通过。`delta=0`、`remaining=14`。

## R8-I02-STOP-F01 / P1

> 最终候选0e2758ec的v3两张836×900中文light14pt完整原PNG经本复核独立解码实算，PNG字节不同，RGBA200、整数白底visible200、alpha0，RGBA与visible半开bbox均为[5,4,831,889)，最大RGBA通道差1。两次原ready/window/receipt一致，原点[48,72]且固定等待5秒仍失败；原body_exit=1、runner exit=1、pilot process_exit=1。微小色阶、相同geometry、alpha0或目视近似不能抵销零容差。截图可比性恢复未认证，按保留的硬停止规则②停止；不诊断compositor、材质、focus、时序或二进制根因，不追加等待、挑帧、掩膜、裁剪或容差。

原要求：保留v3 FAIL、原数字exit和原PNG；继续停止、不计完成、不恢复审美，不以PASS_LIMITED改变视觉或完整契约原判。

处置：接受并保留数值阻断。六张完整PNG、三个终结作业及原数字回执全部归档；不新增v4，不放宽零容差、不追加实验。源码回滚不是截图PASS。

## R8-I02-STOP-F02 / P2

> v3的set-e作业在narrow-pilot失败后立即退出。八组合、正常11gates、5冷启动、三preview及普通34场景A/B全部NOT_RUN，gate-order、narrow-representative、standard-matrix-a/b及source-after-v1均缺席；source-after缺席是未执行，不是PASS。此前v2原capture_verdict恰为PASS_BYTES，只验证复用v1已构建app及延迟脚本副本的两个独立进程中文light14ptPNG字节/RGBA/visible/alpha全0，不是独立新最终app、完整截图链路或根因通过。旧功能补证和旧34矩阵的有限通过不能充作本轮执行。

原要求：本轮normal_gates维持NOT_RUN、full_contract维持NOT_PASSED；保留v2 PASS_BYTES的缩小范围，不重跑三个已终结作业、不借旧PASS闭合本轮。

处置：完整覆盖缺口保留，不补跑GUI、构建或正常gates。v2只认证复用旧app的中文light14pt两进程pilot；旧矩阵与功能补证不扩成round8通过。

## R8-I02-STOP-F03 / P2

> 本次保留的dispatch/config响应请求并配置thinking=max、mode=default；dispatch executedModel仍为null，config明确是configuration only，未提供内部最高thinking实际执行元数据。本会话模型身份、请求/配置max、registry可用档位或旧child配置不等于实际最高档执行认证，actual_execution_thinking保持UNVERIFIED；本复核没有另查、改配置、换provider/model或启用bypass。

原要求：单列请求、配置与实际执行；保留UNVERIFIED及原P2，不把处置有限通过改成最高执行或完整样式契约认证。

处置：请求和配置max已核验；实际执行保持UNVERIFIED，不断言降档或最高档已实执行。不换模型、不重派原复核、不启用bypass。

## R8-I02-STOP-F04 / P2

> 当前本地effective Sources/Tests/scripts对829ba3a9的实际git diff为0；StyleCapture.swift原字节已恢复，活动capture-style-loop-narrow.py不存在，候选两份原字节仍与0e2758ec Git对象相同。branch/HEAD和physical index仍固定在取证候选，本地恢复未提交且工作树有原先冻结的修改/未跟踪文件。此证据只认证本地源码恢复，不认证HEAD已恢复、工作树clean、恢复后的源码重测、Mac共享源码或运行程序恢复；没有本轮source-after或远端恢复证据可扩大范围。

原要求：保持候选HEAD/index与effective源码分列；保留dirty/untracked冻结状态，不提交恢复，不用本地0diff推断Mac代码或运行程序已恢复。

处置：独立复核及父代理接收核验时确实没有stage、commit或push；旧物理index及四份冻结说明原字节另存，冻结历史不改。此原要求的“不提交恢复”保留为独立复核冻结期边界；在复核完成后，父代理按用户既定回滚／同轮归档授权提交源码恢复与停止证据，另留stage／commit／push实际回执，不把新归档头冒充旧取证头。旧未跟踪资产不暂存、不删除；Mac源码及运行程序恢复仍UNVERIFIED，不据本地归档推断。

## R8-I02-STOP-F05 / P3

> 原v3验证器初版读取不存在的plan-original-v3.json；实际作业复制v3输入plan-v3.json时沿用归档名plan-original-v1.json。独立逐字比对确认它确为v3计划而非旧计划；初版脚本、冻结的exit1观察与后续v2验证器exit0数字回执保留。外层提交前末行检查的空行错误与实际5文件snapshot exit0亦分开：原commit消息保留规定bot coauthor，按rstrip后大小写无关核对存在。两项父工具负观察不冒充原GUI或构建exit，也不由后续验证exit0改写v3 runner exit1；本复核不执行会写原件/结果的验证器。

原要求：不改/删除原负观察、脚本、原件或hash，不把验证器成功/回收成功升级成截图成功。

处置：原脚本、失败观察、计划字节、后续数值回执和消息原字节全部保留；只纠正文档中的过时“尚未派发／待完成”，不把工具成功改写成GUI成功。旧120秒timeout124与后续全仓scanner实际exit0也按各自范围分列。

## 同轮归档边界

只归档round8目录、INDEX、STOP，以及已恢复的helper与新增活动脚本删除。父代理接收及首次暂存阶段除四份说明外11,380项输入确实保持；其原回执不追改。首次commit被未修改的安全hook拦下后，另对六份公开JSON作无损源码摘要编码衍生：24处原值均独立核对为实际固定Git源码blob的SHA256，507×6摘要以JSON字节数组表达，避免文件名API／Key／tokens与连续摘要误配。私有原件、220条原来源记录、六份公开旧字节及原review不改；六新副本经解码和逆向逐字恢复原JSON。其余11,374项冻结输入仍保持，六份衍生与四份说明明确分列，不把原独立复核扩大为衍生后的新认证。

衍生范围见[security-publication-overlay-v1.json](contracts/security-publication-overlay-v1.json)。安全hook、默认规则、ignore及权限设置没有修改或绕过；正常或可执行作业计划、源码、截图和容差不变。首次commit实际exit1、未产生归档提交，原负回执保留；修正后仍须经真实hook才能归档。同轮amend保留conventional commit及规定尾注，推送只使用原候选头的精确lease。归档不计轮、不恢复审美、不创建PR或合并main。最终分支头以实际Git及远端回执为准，不能在提交内自引用该提交SHA。
