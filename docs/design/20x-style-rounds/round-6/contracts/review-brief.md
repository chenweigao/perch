# Round 6 / S09 独立契约复核准备

此文件不表示已派发或已通过评审。新 after 严格比较、实际目视、Mac 完整 gates 已实际通过；输入封存及其独立核验完成后才新派 `delegate_task`。

- 指定通道：`acpRegistry_kimi_code`／`aone/gpt-6.1-sol`，当前注册表重新确认最高 `thinking=max`，不换模型。该子任务显式 `mode=default`，避免沿用注册表默认 yolo；不改全局配置／权限。需要真实 `ReadMediaFile` 独立目视，不以能力声明、作者目视或像素数替代。
- 唯一写入：`docs/design/20x-style-rounds/round-6/review-6.json`。不修改产品、证据、原评审、报告、INDEX、seal、branch/HEAD/index；不 GUI、build、PerfRunner、真实连接、配置或权限操作，不归档、计完成或开始下一轮。
- 真实 before 头 `2ded248b7f3d6993841b05c88b33f36add451a92`，唯一新产品／GUI候选 `7e66eb2e5a9dac92eea8d6178e55e7ab5f38e554`；HEAD 外的报告覆盖不是新运行。Source-scope／真实 diff 应仅预览状态 Picker 一行 `fixedSize(horizontal:true, vertical:false)+minWidth130`，其余 strings/tags/binding/options/fonts/padding、S03 Picker、Sources/WorkbenchCore、其他 Sources、scripts/CI/Package 零 diff。
- 冻结契约 `3b1d333c9414f2c87a92159ba22dd98cb6c24620c158f7cf9e6183591329ac60`。34 场景，每矩阵 68 原 PNG／34 双跑：日常八组、首次使用八组共十六既有WB header；原比例半开 `[480,48,1112,104)` 之外双通道零差异，其余十八全窗口零差异及跨作业 PNG 字节相同。
- 实算 RGBA 和白底可见像素、每次 PNG SHA256、场景／机位／有效明暗／语言／xxxLarge、ready/window/screencapture ID、实际 first-use 参数及 marker，不能只采用作者 summary。十六场景不是新增 preview；原 capture driver 字节未变、wrapper 内存扩展唯一场景参数行，实际命令须证明首次使用，不是改名。
- 独立目视 `comparison/headers-first-use.png` 八组与对应原 PNG，当前值均应完整 `首次使用`，标签／箭头／原S03两项当前值无新重叠；日常八组仍 `日常`，Workbench 标题不动。至少查看两组首次使用完整窗口 light/dark，以及主窗口 before/after light/dark；派生图只作索引，原图与裁剪来源需核验。
- 正常非capture native-design 的 12 原 PNG、actual build/WorkbenchChecks/radius/localization/5冷启动／job exit 的真实证据需核对；describe stamp与完整 SHA 不混同。Linux只认证portable10/10，在产品写入后／commit前 baseline HEAD、dirty=true；无Swift，不标Linux完整PASS。
- 原 before consumer FAIL 保留：Mac tar附68个AppleDouble、136个PNG后缀文件，但真PNG68。仅magic验证的传输元数据排除、Mac源数、所有真实图片／JSON日志原字节与v2逻辑视图对应独立核验；不把传输适配失败说成视觉回滚，也不把失败抹为PASS。完整whitespace失败、精确原日志例外及 post-push TLS查询负回执保留；当次Git数字未捕获，不补造。
- 原 round2四项、round3五项、round4九项和round5一项共19条历史发现及原文、等级、来源、未认证边界逐字保留；round4目视补证保持原字节。原round2视觉FAIL/完整契约NOT_PASSED/撤回，round4原FAIL与有限PASS_LIMITED分开，不能重判。
- 全部已裁决玻璃／sidebar／inspector／framePanel圆角／系统跟随／Settings／默认light原方向不重开；不裁美。固定组合不是任意宽度／所有选项／全应用18pt或全局OS切换、全compositor光学、真实连接／权限／性能、隐私／许可／全历史秘密审计。保留已有全部认证边界。
- 写前、写后、最终检查均验证 seal 所有 file/SHA256/mode/kind 和本轮输入不变；保留实际工具中断／错误等操作回执。新发现逐字写 finding_verbatim 和来源；FAIL／PASS_LIMITED仅在其实际覆盖范围签发。
- 当前本轮不计完成，剩15轮；父代理在独立契约通过、发现逐字处置、同轮归档和精确推送／源码验证后才计15→14。完成通过 T3 唤醒，不轮询运行子任务。

## 已完成的实际证据与输出约定

- `style-r6-after-v1` 于15:18:56终结exit0，`style-r6-gates-v1` 于15:30:55终结exit0，完整候选与文件内容分别核验；描述印记实际为 `v0.8.1-315-g7e66eb2e`，不是完整SHA。136矩阵＋12正常native-design＝148原PNG；原件和发布副本的 gates validator 均实际exit0。详见 `contracts/gates-original-validation.json`、`contracts/gates-publication-validation.json`、`contracts/mac-gates/style-r6-gates-v1.log`。
- 原件打包与发布对应 hash 表均保留；after无传输元数据排除，gates以 `filter=data` 实际解包、逐字比对原包全部普通文件。只认证模式扫描0 findings，不把它当成图像隐私／许可或全历史秘密审计。
- 新保留边界：after整体本地消费shell退出141发生在全部PASS输出后的最后 `jq|head` 摘要显示；不能升级整体shell为exit0，也不能当作GUI／像素FAIL。解包的Python告警原文保留，有界重读没有重拍或重跑消费器；原callback工具会话标识只作历史索引。
- `contracts/historical-findings.json` 包含round2／3／4／5四份原评审各4／5／9／1项完整原对象及原verdict，总19项；独立对照原文件hash和内容，不重判round2／round4的原FAIL。
- 唯一输出 `review-6.json` 至少包括：`verdict`（可FAIL或限定PASS_LIMITED）、`all_required_frozen_contract_and_visual_checks_completed`、`finding_counts`、`blocking_findings`、`findings`、`historical_findings_ledger_sha256`、`uncertified_boundaries`、实际工具／图片覆盖和写前／写后／最终seal检查。每条新finding带 `id`、`severity`、`blocking`、`finding_verbatim`、其UTF8 SHA256及证据来源；不预置通过或零发现。若独立目视／保护核验不全则如实FAIL，不以作者结果补签。
- 可只读运行本轮比较器及 `verify-review-archive.py --inputs-only --seal-sha256 <任务中冻结值>`；无输出参数时不写文件。`GIT_OPTIONAL_LOCKS=0` 避免读git刷新index；写前后必须检查原seal全部hash/mode/kind及物理git index摘要，不修原输入。
