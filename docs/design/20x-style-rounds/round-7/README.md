# Style loop round 7：暗色 quiet 层级对称性

日期：2026-11-19。队列项：S04。状态：**视觉 FAIL，完整契约 NOT_PASSED**。before／after 各34/34双跑、共136原PNG及机位／fixture验证通过，但原件与发布副本的跨作业color比较均实际exit1；light查找栏出现清单外色阶变化，dark查找栏违反中性步进，Workbench-dark缺少预写必需变化。Theme三行已恢复基线，停止后续审美／GUI作业；Mac完整gates未派发。独立回滚／停止复核已完成，限定结论PASS_LIMITED；七项新发现逐字登记处置，四项候选／完整契约阻断保留。本轮不计完成，距汇报仍14轮。

## 单一假设与边界

- round 6 最终归档／远端头 `ec3372c8d81dd5844bbfc4bdf5d973be80ef2bb4` 已精确核验；148 原 PNG、独立 PASS_LIMITED、唯一 P3 逐字处置及 15→14 已闭合，不重派旧作业或评审。
- 新轮 fetch 前两次实际 exit128，第三次普通 fetch exit0；main 仍 `65cf2fc67623a916f12797371d1ca087c911b24f`，已包含，无 merge／冲突。原负回执保留，不改网络、TLS、凭据或权限配置。
- 只把 `WorkbenchTheme.quietNS` 的 dark `(0.520,0.550,0.610)` 提高至 `(0.540,0.570,0.630)`；light `(0.43,0.43,0.45)` 与正文 ink 不动。仅同步两处既有对比度数值描述，不新增控件、布局、preview、字体、选项或行为。
- quiet 是共享前景层，不只供时间戳：辅助文字、计数、箭头、离线等图标及同 token 辅助绘制一起受影响；覆盖主窗口和三个既有 preview，不事后把已知共享引用排除或扩区。
- [预写差异](expected-differences.md)与[色彩／固定机位契约](color-geometry-before.json)先于新 GUI 和产品写入。只用新 before 生成固定前景掩码，冻结后才改产品；清单或掩码外差异即撤回，不改规则迎合 after。

## 三层证据计划

- 契约：Linux portable；Mac WorkbenchChecks、radius、localization、三个既有 preview、production build、5/5 冷启动与正常非 capture native-design。未执行的 Linux Swift／WorkbenchChecks不算 PASS。
- 视觉：复用已验证的 34 场景 capture 矩阵，before／after 各双跑 68 原 PNG；固定明暗、机位、语言、字号及首次使用参数。19 个 light 场景必须全窗口 RGBA、白底可见像素及跨作业 PNG 字节零差异；15 个 dark 场景只允许预先冻结的前景掩码内色彩步进，alpha、几何和背景不变。
- 回归：中英文、默认／xxxLarge 代表 fixture，主窗口与三个既有 preview 的 light／dark 实际目视。xxxLarge 不扩认全应用18pt；源码系统跟随／默认 light 不变不替代全局 OS 切换认证。
- 独立评审只裁冻结契约、红线、清单与图像一致性，不裁美；原 round 2／4 判定及历史未认证边界保留。完整证据、独立复核与同轮归档前仍剩14轮。

## 续作锚点

- 唯一新作业／support：`style-r7-before-v1`／`style-r7-support-v1`；未终结时不重派同名或换名作业。
- GUI 只走串行 PerfRunner；性能循环 INDEX 已记录用户于2026-11-18结束，入队仍核验队列和共享 checkout，不直接在 SSH 内构建或操作窗口。
- WorkbenchCore、其他 Sources、测量／CI 语义零 diff；不动旧 round 0／4 未跟踪产物，不开 PR、不合 main，不碰真实会话／远端／凭据或权限。

## 实际证据与时序

- 唯一 before 于17:12:24原子入队，job SHA256 `f105ca02922cf5124c7f68296b0a395ad93362a0ec8ff9a1f6850976a093a63f`；17:21:02 terminal exit0，499.335秒，前后共享 checkout clean，实际代码头`ec3372c8`。[原回执](contracts/mac-before/mac-before.log)与[入队／读取记录](contracts/start-receipts/)保留；不重派。
- 原 tar SHA256 `0ea93bc4fdcbd74af1d8512e984a04e927213a6bbaa4604ae14baab3f3aa8fa1` 两机一致，456成员／352普通文件、68原PNG，安全相对路径／普通文件原字节／PNG magic验证通过，AppleDouble为0、明确使用`filter=data`。[归档验证](contracts/before-archive-validation.json)保留，不重拍。
- [原件](contracts/before-original-validation.json)和[发布副本](contracts/before-publication-validation.json)都验证34/34双跑、68原PNG与全部固定机位／fixture。发布只脱敏机器home前缀和规范JSON斜线，原PNG字节不变、原文本外部保留；不将模式扫描扩认图片隐私或全部凭据格式。
- 六张完整原图实际目视：[索引与观察](contracts/baseline-visual-validation.json)。主窗口中文默认、英文xxxLarge，Workbench首次使用英文xxxLarge，以及Sidebar／Composer dark覆盖；不声称全部原图逐字人工验收或全应用18pt。
- [18项合成控制](contracts/quiet-controls.json)通过：背景排除、quiet seed、边缘膨胀／不回绕、中性色步进边界、light／掩码外／alpha／隐形RGBA拒绝与profile锚点拒绝。[身份负控制](contracts/identity-negative-control-validation.json)以同一before代替after，实际process exit1且仅缺少main-dark／Workbench-dark必需变化，作为正确拒绝；不是实际after或GUI失败。
- 17:29:03、源码／HEAD仍未改时生成[15张固定掩码](frozen-masks.json)，payload SHA256 `7418ab2190596ee647a4f5f6db41e2fcda6aeb806b4dcc58ec4c55e001710104`，comparer SHA256 `6d7f2e3ca2abd18504b08b69d2d40347c1627893f6b85652f28e429b5bde5589`。后续比较必须显式传原payload摘要；透明背景的隐藏RGBA也不得变化，原规则／源文件不为after修改。
- 17:43:06才写入产品：dark quiet三通道各加0.020、两处既有数值描述4.7→5.1；[源码范围](contracts/source-scope.json)和[精确patch](contracts/source-change.patch)证明只有Theme三行允许替换，light／正文／其他token／布局／行为及其余Sources／Tests／scripts／CI不变。
- [Linux portable](contracts/linux-portable/results.json)实际10/10、process exit0，运行时HEAD为baseline`ec3372c8`、dirty=true且产品已写入；[来源边界](contracts/linux-portable-attestation.json)明确不认证Linux Swift／WorkbenchChecks、clean候选或完整Linux PASS。原round2／3／4／5／6共20条finding及原verdict已[逐字固定](contracts/historical-findings.json)。
- after／gates脚本已准备并通过bash语法校验。17:49:42原候选提交进程实际exit0，保留正常hook及作者尾注，不重复提交；17:57:00正常显式refspec push实际exit0，17:57:02精确远端核验main仍`65cf2fc6`、样式分支为完整候选SHA。
- 17:57:59唯一`style-r7-after-v1`原子入队；job SHA256 `0dfa1d6c7f5d1620c3487540040726c53c5f9d44a14815ea71c823b8e1c84c78`。入队前runner69667、队列空、共享checkout clean及原before／support摘要核验通过；这是排队回执，不是截图或契约PASS。after实际零清单外差异及目视通过后才派完整gates，独立复核／同轮归档前仍剩14轮。

## 失败、回滚与停止处置

- 唯一after于18:05:50终结exit0，capture耗时463.866秒，34/34双跑与68原PNG有效；这是GUI矩阵执行成功，不是跨作业视觉通过。原tar SHA256 `fd4807954ed5539bea8cdd4020842d9f6ebd06976ab9622a26167ea0998f9342` 两机一致，458成员／354普通文件、无链接／越界／AppleDouble，明确`filter=data`及全部成员原字节核验通过。
- 原件color比较18:07:24实际exit1；发布副本18:14:10实际exit1，[双消费核验](contracts/dual-failure-evidence-validation.json)证明完整结果除记录时间外相同，不能以双跑稳定或发布一致覆盖视觉FAIL。
- `main-find`：32,953个RGBA／可见像素变化，全部在light清单外，bbox `[276,46,1218,95)`；其中28,911像素从`[235,231,237,255]`变为`[233,229,236,255]`。`main-find-dark`：38,005变化，其中36,298违反只许中性提亮的颜色规则。alpha及隐藏透明RGBA变化均为0；其余预写限制不放宽。
- `main-dark`等四个非查找dark场景的局部quiet提亮符合掩码／步进，但不能抵销上述FAIL。`workbench-dark`实算0变化，违反预写必需变化；保留原假设与冻结文件，不删除该要求迎合结果。材质／捕获状态、编译产物或token实际可见作用域的因果均未认证，不把原因写成已确认产品回归或已修好的基建问题。
- 失败后仅在本线程工作树逆向恢复Theme三行；[源码恢复核验](contracts/rollback-source-validation.json)确认SHA256回到`64c9baba01460a8f062ee9c4db732be6d1577ad0d3432f2024fb436317f57e95`，相对`ec3372c8`所有Sources／Tests／scripts／CI／Package／AGENTS均零diff。真实测试候选及复核阶段HEAD/index仍`5970638a64a73e352867ad8e5ffeca9341f9d66b`；恢复后的源码及最终文档归档头不冒充重新测试，复核后的归档状态另由Git及数字回执核验。
- **Mac production build／WorkbenchChecks／radius／localization／5冷启动／正常native-design未派发，NOT_RUN；没有原生回归PNG。** Linux仅保留先前实际portable10/10，不称完整Linux PASS。没有另起after或gates，不启动S05、不计轮，不把裁剪替代原图。
- 按原停止规则②先停止迭代并归档未解释的跨作业可见漂移；不是用户审美否决，也不是20轮汇报点。独立复核只核对失败证据、回滚、红线和停止处置；后续恢复须先修复并验证截图可比性，不能复活本轮候选或修改本轮掩码。

## 附加证据边界与截图索引

- 首状态查询v1实际exit0但先查保留的`.job`，输出`queued`时已有14原PNG；原行保留，不认证尚未启动。新只读v2先查terminal／log，18:06:29取得唯一after的真实terminal。只修观察分类，不重派或改变GUI作业。
- 18:22:07[Mac停止短查](contracts/failure-and-stop-receipts/stop-observation-v1.log)实际确认runner69667、队列0、before／after均terminal exit0，无gates或下一轮入队。共享树仍为真实候选`5970638a`且clean，不误称Mac源码已回滚；最终本线程同轮回滚归档前没有新GUI。
- 恢复核验原v1把空cached diff过度写成物理index未更新；原[v1](contracts/rollback-source-validation-original-v1.json)保留，[v2](contracts/rollback-source-validation.json)只认证源字节和无staged语义diff，不回填此前物理index摘要。后续独立保护从新seal开始，不扩认之前的期间。
- 首新增发布snapshot实际exit1／449文件／1个作者邮箱模式finding；只对公开提交回执的已知bot邮箱脱敏，并注明命令字段非未脱敏原件，真实Git尾注／私有原回执／初版副本不变。第二次450文件／0findings／exit0；不改scanner、豁免、权限或网络配置。[脱敏续证](contracts/publication-email-redaction-v1.json)补充初版发布manifest，不追改首次negative日志。
- 父线程本地归档扫描v1的三项scanner进程实际exit0，但数字回执封装使用jq保留字`end`而出现三次语法错误，生成的三份空receipt不认证数字退出码；原log、空文件和实际工具stdout保留。v2仅修外层记录器、检查receipt构造退出码并使用新路径复验，不改scanner或GUI；最终扫描状态以新数字回执为准。此为父线程归档观察，不追改独立review的七项finding或原判；后续[处置再验](contracts/archive-disposition-revalidation.json)与首版验证分别保留。
- 原件before／after各68PNG：[before](before/)、[after](after/)；主窗口light/dark：[before light](before/main-light/repeat-1/capture.png)、[after light](after/main-light/repeat-1/capture.png)、[before dark](before/main-dark/repeat-1/capture.png)、[after dark](after/main-dark/repeat-1/capture.png)。
- 失败查找栏：[before light](before/main-find/repeat-1/capture.png)、[after light](after/main-find/repeat-1/capture.png)、[before dark](before/main-find-dark/repeat-1/capture.png)、[after dark](after/main-find-dark/repeat-1/capture.png)；[light 3×](visuals/main-find-3x.png)、[dark 3×](visuals/main-find-dark-3x.png)及[原摘要／坐标](visuals/crop-provenance.json)只作观察，不参与像素判定。[父代理实际目视记录](contracts/failure-visual-inspection.json)为八张原图及两张派生图，不扩认为完整矩阵逐字验收。
- 三个既有preview同机位完整图均保留在矩阵中：Workbench／Sidebar／Composer的light/dark及已有语言／字号组合；未声称本轮已人工逐字认证全部组合或全应用18pt。
- 独立[review-7.json](review-7.json)已完成：PASS_LIMITED仅覆盖失败证据、本线程源码恢复、红线及停止处置，实际目视八张完整原图＋两张3×观察图。新P1×3／P2×1／P3×3均[逐字处置](review-disposition.md)；候选交付及完整契约四项阻断继续保留，不宣称修复或授权恢复。原20个历史finding对象／原判未变。
- 父线程在处置前实际复验原seal，11163项输入及复核期physical index未变；复核后只允许README／INDEX／STOP说明变化并保留原字节快照，新处置验证单列。最终同轮归档头以`git log -1 --format=%H -- docs/design/20x-style-rounds/round-7/README.md`核实，推送状态以外部精确远端数字回执为准；未取得回执前不宣称已发布。迭代仍停止，计数仍14。全轮状态及续作条件见[停止总结](../../20x-style-loop/STOP-20261119-R7.md)。
