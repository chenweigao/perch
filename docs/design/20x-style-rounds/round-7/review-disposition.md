# Round 7 / S04 独立停止复核逐字处置

日期：2026-11-19（+08:00）。原评审 `review-7.json` 的 `PASS_LIMITED` 仅指失败证据、本线程源码恢复、红线及停止处置；`visual_verdict=FAIL`、`full_contract=NOT_PASSED`、恢复未授权均保持。七项新发现为 P1×3、P2×1、P3×3；四项候选／完整契约阻断保留，不把撤回处置等同修复或验收通过。本轮不计完成，仍剩14轮。

真实测试头：`5970638a64a73e352867ad8e5ffeca9341f9d66b`；恢复基线：`ec3372c8d81dd5844bbfc4bdf5d973be80ef2bb4`。原评审 SHA256：`004c000b4f47420b3f09dde23d5dfd5f0bb8c1792bb2d03b6ff4483922633621`。不改原评审、历史20个发现对象／原判、原PNG、冻结规则、原日志或原seal。

## S04-R7-F01 — P1，候选视觉／完整契约阻断保留

原发现逐字保留：

> 从本轮唯一 before/after 的 main-find 原 PNG 独立解码并以整数白底合成、RGBA 与 PNG 字节零容差重算，得到 32,953 个 RGBA/可见变化像素，全部属于 light 清单外，半开 bbox 为 [276,46,1218,95)。其中 28,911 像素从 [235,231,237,255] 变为 [233,229,236,255]，跨作业两个 repeat 的 PNG 字节均不同。light 预写要求是全窗口三项零差异，不允许以微小色阶、同侧双跑稳定、几何/alpha 不变或四个其他 dark 场景合规抵销。候选视觉 FAIL，S04 撤回；查找栏底色的因果未认证，不宣称 focus、材料、编译产物或 token 根因已确定/已修复。

原处置要求逐字保留：

> 保留失败原 PNG、exit1 与预冻结规则；维持撤回/停止，不换图、不扩 mask、不调阈值、不计完成。

处置：接受。保留 light 32,953 清单外像素及原件／发布副本两次 color exit1；Theme 恢复基线，S04 撤回、规则②停止。没有替换图片、修改 mask、阈值或预写清单，未计完成。此项不是已修复的截图或产品问题；原因仍未认证。

再验：原 seal 覆盖失败PNG、比较结果、预冻结文件及源码字节；逐字引文与原评审比对，结合 [双消费失败证据](contracts/dual-failure-evidence-validation.json) 留存原判。归档保护结果另见 [处置验证](contracts/review-disposition-validation.json)，不补跑GUI。

## S04-R7-F02 — P1，冻结颜色契约阻断保留

原发现逐字保留：

> main-find-dark 原图独立重算有 38,005 个 RGBA/可见变化像素，其中 36,298 像素违反原 RGB 与 white-visible RGB 每通道仅许 0–8 中性提亮、增量跨度≤3 的冻结规则。mask 外、alpha 和隐藏透明 RGBA 的变化均为 0 仍不能使它通过：在 mask 内也不得变暗/换色。38,005 是总变化，不把其中合规的 1,707 像素说成违规；整体 bbox [276,46,1422,859) 同时包含查找栏与合规辅助前景。完整原图及 3x 对照实际目视看到查找条底色色阶差异，具体数量来自原 PNG 实算而非目视/OCR。四个非查找 main dark 场景的局部提亮合规不抵销这项 FAIL，因果继续未认证。

原处置要求逐字保留：

> 维持颜色 FAIL 和规则②停止；不能因 geometry/alpha/隐藏 RGBA 或发布副本一致而改判，不认证或修补根因。

处置：接受并保留阻断。38,005 总变化与36,298违规分别记录；合规1,707像素不抵销违规。几何、alpha、隐藏RGBA或发布一致不替代颜色契约，不改判、修补根因或恢复队列。

再验：冻结 profile、mask、comparer 与原比较日志／原PNG的 hash、mode、kind 保持；原引文、数值和停止状态对照复核，不重新解释为视觉PASS。

## S04-R7-F03 — P1，预写必需变化缺失保留

原发现逐字保留：

> 预写 required_changed_scenes 同时要求 main-dark 与 workbench-dark 真实变化。独立原 PNG 实算 main-dark 有 1,707 个受控变化像素，但 workbench-dark 为 0，两个 repeat 的 before/after PNG 字节亦完全相同；指定 Workbench-dark 全窗口前后原图已实际目视。普通逐场景 pass=true 仅表示无不允许的差异，不含另列的必需变化检查；missing_required_changes=[workbench-dark] 仍使整体 color FAIL。不得删除 Workbench 必需变化要求迎合 after，也不能把未满足假设写成 token 作用域根因已认证或截图/产品问题已修复。

原处置要求逐字保留：

> 保留冻结要求、缺失变化及未认证作用域；不接受 S04、不计轮、不补派本轮作业。

处置：接受。`workbench-dark` 的0变化和必需变化缺失继续使整体FAIL；不删除冻结要求，不接受S04或补派作业。共享token实际可见作用域仍未认证，不把假设未满足写成根因或修复结论。

再验：原预写差异、profile、原比较与PNG摘要不变；INDEX及STOP均保留缺失变化、S04撤回及14轮计数。

## S04-R7-F04 — P2，完整 Mac 契约覆盖阻断保留

原发现逐字保留：

> 本轮完整 Mac gates、production build、WorkbenchChecks、radius、localization、5 冷启动与正常非 capture native-design 未派发，均为 NOT_RUN，没有对应本轮原生回归 PNG。原 wrapper/manifest/log 仅证明每个 capture job 内 host build 与三个既有 preview build 实际 exit0，以及离线 capture fixture/截图执行；名为 native-design 的 capture fixture 不是正常非 capture 回归。两个 GUI terminal exit0、portable 10/10 或准备好的 gates 脚本不等于完整关卡 PASS。按视觉失败先停止、未派后续 gates 的处置合规，但完整契约一直 NOT_PASSED。

原处置要求逐字保留：

> 分列 capture/preview build 与完整 Mac gates；保留 NOT_RUN/无原生 PNG，不在复核中补跑、恢复迭代或缩小原完整交付契约。

处置：接受并保留完整契约阻断。README／INDEX／STOP分列capture及三个既有preview构建与完整Mac gates。production build、WorkbenchChecks、radius、localization、5冷启动和正常非capture native-design全部NOT_RUN，无本轮原生PNG；Linux只保留先前portable10/10。不补跑、不缩小完整交付契约、不将GUI执行exit0改判为完整PASS。

再验：保护原job、manifest、log、gates准备脚本及停止回执；本次只做本地文档、Git、JSON、hash／mode／kind与公开模式检查，没有新SSH、GUI、构建或PerfRunner作业。

## S04-R7-F05 — P3，观察分类修正与原缺陷保留

原发现逐字保留：

> after 观察 v1 于 18:01:20 实际 exit0，但先查保留 .job 再查 log，输出 state=queued 时已有 14 原 PNG 且共享 HEAD 为测试候选。独立读取旧 observer、原日志/数字回执与公开副本，确认这不是尚未启动的证明。v2 按 terminal→log→无 log 的 job 顺序分类，18:06:29 实际读取唯一 after 的 18:05:50 terminal exit0 与 68 PNG。旧 queued 行、observer 和原回执保留；这项只读观察分类纠正不重派 capture，不改 GUI/产品，也不把观察器 exit0 升级成 color PASS。

原处置要求逐字保留：

> 保留 v1 负精度记录与 v2 范围，不把旧行抹成 terminal 或据旧 queued 重派作业。

处置：接受已完成的v2分类纠正，原v1误分类记录及数字回执全部保留。没有据旧`queued`重派after，也没有改原行、GUI、产品或color判定；本次不扩认观察器的认证范围。

再验：原v1/v2 observer、日志、回执与公开副本受原seal保护；[原纠正说明](contracts/failure-and-stop-receipts/after-observer-correction-v1.json)字节不改。

## S04-R7-F06 — P3，公开脱敏与首次失败回执保留

原发现逐字保留：

> 首新增公开 snapshot 实际 exit1、449 文件、1 个 bot coauthor 邮箱模式 finding；独立核对数字回执，并在初版保留的公开 commit receipt 上以原 scanner 纯函数确认该 1 项。仅当前公开 commit receipt 的命令参数显式脱敏并加注，真实 Git 尾注、私有原件和初版公开副本字节不变；真实尾注与私有原命令已用 bool/hash 核对，公开 JSON 不复制邮箱。后续实际 450 文件/0 findings/exit0，原 20 项 source hash 全部匹配，19 个旧 pubhash 加 1 个授权 redaction hash 续证通过；初版 manifest 和首次失败未重写。后来的 850/0、loop 3/0、root 8648/0 仅为 pattern check，不证明图片隐私、所有凭据格式、身份历史、许可或所有权。

原处置要求逐字保留：

> 保留初次 exit1 和原 bytes，仅承认明确公开脱敏，不改 scanner/豁免/config/真实尾注，不扩认隐私或凭据审计。

处置：接受原显式公开脱敏，保留首snapshot exit1／449文件／1finding、初版manifest、真实私有命令及Git尾注。当前公开回执仅按既有注释脱敏，原19项pubhash及一项授权redaction续证不追改。本次继续使用原scanner，不改豁免、配置、权限或真实尾注；0 findings只指既有模式检查，不认证完整隐私、凭据格式、身份历史、许可或所有权。

再验：初版与续证JSON、原失败日志、公开脱敏字节及scanner均由原seal保护；发布前重新执行原公开模式检查，真实数字退出码另存，不预写PASS。

## S04-R7-F07 — P3，旧物理 index 过度认证不追认

原发现逐字保留：

> 源码 restore 原 v1 将空 cached diff 过度写成 physical_index_not_updated=true。该原 v1 私有件及 original-v1 公开副本 SHA256 69edd692a8f12c6d78100b549a75bfdba177c88cbde43082ddc92da2818da755 均保留；v2 只签源字节恢复与无 staged 语义 diff，不追认此前物理 index。独立当前 Git 读取确认 worktree Theme 等于 parent，HEAD/index Theme 仍是候选、cached diff 空，不能误称整个 worktree clean 或 HEAD 已回滚。物理 index SHA256 8cb0c296fe7a3e186db80263fb6d36ccb1e6bd5652e53217e511b21e8ad97db6 只从本 seal 期实际保护，不扩认之前；本线程恢复也不证明 Mac 共享树已回滚或恢复后的字节已经重测。

原处置要求逐字保留：

> 继续分列源字节、staged 语义、物理 index、候选 HEAD、本线程 worktree 与 Mac 状态；不修原 v1、不补造旧 index 摘要、不 amend/提交。

处置：接受原v1过度认证边界；原v1/v2及上述摘要全部保留，不补造此前物理index。独立复核结束前及父线程19:17:21原seal再验时，HEAD/index仍候选、worktree Theme已恢复、cached diff为空；该阶段不amend／提交的约束已遵守。之后父线程依用户原每轮归档契约，仅对自己本轮候选执行同轮回滚归档；这是复核结束后的显式状态转换，不追改复核时点，也不是评审授权恢复产品或审美迭代。归档后HEAD/index的新摘要与原seal阶段摘要分开记录。

再验：保护全部11163项输入，仅README／INDEX／STOP三份状态说明允许在复核结束后更新，并保存原字节快照；新处置文档和验证结果单列。源码仍对`ec3372c8`零diff，最终归档头不冒充重测头。Mac共享树最后原回执仍候选，不因本地归档／推送推断Mac已回滚。

## 历史原判、保护及归档边界

- round2／3／4／5／6共20个原发现对象、原verdict、round4原FAIL与单独目视PASS_LIMITED均逐字保留在原 [历史manifest](contracts/historical-findings.json) 和原独立review中。
- 原seal SHA256 `9720e2be9e5e46a6da050d4f800ba0b96ad7d35305f249318f5c3240d0ed5867`。父线程19:13:55及19:17:21实际原seal再验通过；11163项hash／mode／kind／inventory和当时branch／HEAD／physical index不变。外部原字节快照在发布脱敏路径 `/home/developer/code/_evidence/style-loop-round-7-20261119/parent-archive-originals-v1/`，实际路径由本线程handoff指向。
- 处置再验使用外部 `verify-rollback-archive-v1.py`，逐字比对七项finding及原处置要求、原review／seal摘要、历史原对象、受保护输入、允许说明快照、源码红线与14轮计数；实际结果为 [review-disposition-validation.json](contracts/review-disposition-validation.json)。该结果不认证视觉或完整Mac契约，不预先宣称尚未执行的stage／commit／push成功。
- 首版处置验证保留其实际时点的说明hash；README补记本地扫描回执封装错误后，使用新的 [archive-disposition-revalidation.json](contracts/archive-disposition-revalidation.json) 再验当前说明。原scan log与三份空receipt不修写，修复外层记录器的v2复验结果另列；不把该父线程观察改写为独立review新增finding、视觉FAIL或Mac gates失败。
- 同轮归档只stage Theme逆向撤回、本round7、INDEX和STOP，不碰旧round0七目录或round4两份未跟踪seal。完整whitespace诊断与精确原日志例外分列保留，不修剪证据。真实测试头、归档头及精确远端回执分开，不改round6或开新提交轮。
- 不重派已完成review／GUI，不启动S05、不计轮、不开PR、不合main、不碰真实连接／数据／凭据或权限。恢复截图基建及任何后续迭代仍须用户明确恢复指示。
