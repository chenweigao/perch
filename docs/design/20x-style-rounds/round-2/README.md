# Style loop round 2：inspector 标题宽度

日期：2026-11-18。候选：S02。产品基线：`0a83a8d01c31e904d7952af4cacea2b88173aa1d`。
本轮 fetch 的 main：`9ed2ac1c609e78e263273aeef8504911c1c82f13`，已包含，无需 merge。
状态：候选版本视觉契约失败，产品修改已回滚；触发基建停止规则②，停止后续审美迭代。
本轮未计完成，距用户汇报仍为 **18 轮**。独立处置评审已完成：回滚／停止 `PASS_LIMITED`，
候选视觉 `FAIL`，完整契约 `NOT_PASSED`；不授权恢复迭代。
未开 PR，未请求或执行合并。

## 单一假设

标题与计数、固定尺寸的原生控件及水平留白竞争宽度。只调整
`ChangesInspectorView.header` 的非内容水平留白，不改 inspector 宽度、字号、计数、
控件尺寸、行为或内部辅助道结构。预期见 [清单](expected-differences.md)。
被撤回的唯一产品修改：header 外层 `HStack` 的 spacing 从 6pt 改为 0pt，回收四个空隙共 24pt；
原有 24/28pt 控件尺寸、16pt 水平 padding、字号和内层标题/计数间距均不变。
支持性系统字体测量中，完整标题宽 154.90pt、`2 files` 宽 34.10pt；
实际是否完整、是否重叠仍以 after 图验收，不用字体测量代替截图。

## 已发生的作业伪影

- `style-r2-before-v1` 在 2026-11-18 16:34:01 开始，exit 1；截图比较数为 0。
- 原因是新作业沿用了已存在的默认 host app 路径，同时传入 `--build-host`。
  `check-host-lifecycle.py` 正确拒绝：`--build-only requires a new --app path and no --phase`。
  这是 CLI 参数契约失败，不是产品编译失败、截图漂移或 PerfRunner 会话失效。
- 修正作业 `style-r2-before-v2` 使用新的作业专属 host app 路径；旧 app 与失败产物原地保留。
  同时显式复用 round 1 已验证的 Node 截图 helper，不改 TCC、权限、SSH 配置或 runner。
- 预期清单在第一次作业前已写入，原作业记录的 SHA-256 为
  `31bf8ee69518b0c539718890ad0e4d6d99262a712c100f4d7b5fa41aaead1098`。
  清单不按后续截图扩大范围；只有取得有效 before 图后才固定像素区域并修改产品。

## 已完成的 before 证据

- `style-r2-before-v2`：2026-11-18 16:42:03 至 16:48:54（+08:00），exit 0；porcelain 前后均为 0。
  起点采用原作业日志的 `start=2026-11-18T16:42:03+08:00`；先前说明误写为 16:42:06，相差三秒。
  本次只纠正文档，不改原日志、不重跑作业。
- [manifest](before/manifest.json)：22/22 场景 repeat-1/repeat-2 PNG 字节一致，共 44 张原始 PNG。
- 三个既有 preview 构建与新隔离 host 构建均成功；fixture 与机位元数据保持固定。
- [header 观察图](before-header-observations.png) 为 before 图的 2× 标注裁剪；
  [来源与坐标](contracts/before-header-observations.json) 可独立重建。原始 PNG 未修改。
- [像素允许区](allowed-regions-before.json) 在产品修改前固定，SHA-256 为
  `f03ac93a74196675275ad7b602b58575b479117e466b7549cb54868b5c7f6b90`。
  矩形仅覆盖 inspector header，不包含 toolbar 或首个文件行；未展示 inspector 的场景与 preview 不允许变化。
- [比较器 self-check](contracts/comparison-self-check.json)：同一 before 矩阵对比 22 场景全为零差异。

## 三层证据

### 1. 契约层：未全部通过

| 检查 | 实际结果 | 证据 |
|---|---|---|
| Mac `scripts/build.sh` | PASS，候选头 `92b718d5` | [build](contracts/mac-gates/build.log) |
| Mac `swift run WorkbenchChecks` | PASS | [checks](contracts/mac-gates/workbench-checks.log) |
| Linux portable | 10/10 PASS，radius/localization/preview-sources 均包含 | [results](contracts/linux-portable/results.json) |
| Mac radius/localization | 已执行成功 | [radius](contracts/mac-gates/radius.log)、[localization](contracts/mac-gates/localization.log) |
| 生产 WindowGroup 冷启动 | 5/5 PASS | [result](contracts/mac-gates/app-launch/result.json) |
| 既有三个 preview 与 host 构建 | before/after 均成功 | [before manifest](before/manifest.json)、[after manifest](after/manifest.json) |
| Mac gates 整体作业 | exit 1，不写整体 PASS | [log](contracts/mac-gates/style-r2-gates-v1.log) |
| 正常 native-design 外观切换 | 未执行；前置断言错误提前退出 | [log](contracts/mac-gates/style-r2-gates-v1.log) |
| 回滚后的 Sources/测量/CI 红线 | 相对 `0a83a8d0` 为零产品 diff | [rollback](contracts/rollback-product.diff) |

gates 作业错误地把 `PerchSourceRevision` 与完整 Git SHA 比较。原 `build.sh` 按
`git describe --tags --dirty --always` 写入，真实结果为 `v0.8.1-283-g92b718d5`。
5 次冷启动已通过，作业在随后错误断言处退出，native-design 没有执行；不重跑已完成作业，
不把描述字符串误判成错误代码头，也不为未执行覆盖背书。

portable 的 `dirty=true` 来自新证据与保留的旧 round-0 未跟踪产物，不是未提交产品修改。
一次汇总查询误用 `.results` 而不是实际 `.checks` 字段，jq exit 5；原测试 CLI 已输出 Passed，
按正确 schema 核对 10 项 exit 0，不重跑或把显示命令错误记成产品失败。

### 2. 视觉层：FAIL，立即回滚

[逐像素对照](visual-comparison.json) 核对全部 22 组 before/after、机位/fixture 元数据与 manifest PNG hash。
before/after 各自 22/22 组双跑逐字节一致；**跨作业对照不满足清单**。

- 11 个展示 inspector 的主窗口场景，变化全部在预写 header 区域内；其余主窗口无变化。
- 英文 14pt/18pt、light/dark 四组中，候选的 `Current workspace diff` 完整显示、计数完整，控件不重叠。
  [2× 对照](rejected-header-before-after.png) 与 [来源](contracts/rejected-header-before-after.json) 仅用于说明被撤回候选，不代表已交付。
- `composer-dark` 出现 **376604** 个清单外可见像素，bbox `[0,0,760,500)`；其他八个 preview 场景零差异。
  例如 `(380,250)` 的 RGBA 从 `(31,27,39,255)` 变为 `(30,28,37,255)`。
  [before](before/composer-dark/repeat-1/capture.png)、[after](after/composer-dark/repeat-1/capture.png) 的机位、外观、语言与字号元数据一致。
- Composer preview 的全部显式编译输入在基线与候选之间零 diff：
  [输入红线](contracts/composer-inputs.diff)。其系统窗口背景未显式固定；窗口 tint 是诊断候选原因，**未作因果认证**。

不扩大允许区、不忽略 1–2 级 RGB 漂移、不重做 after 来挑选有利截图。
发现清单外差异后立即将 spacing 恢复为 6pt；[被撤回 diff](contracts/rejected-product.diff) 保留真实候选，
[回滚验证](contracts/rollback-product.diff) 证明产品恢复到上一完成轮。S02 仍未解决。

### 3. 回归层：部分证据，未认证项明确保留

本轮补英文 dark、英文 18pt light/dark、中文 18pt dark 四组主窗口组合，不新增 preview 或验收页面。
主窗口上述中英/字号/外观代表图可比；2× backing scale、其他窗宽和更多文件计数未覆盖。
系统外观跟随与 fixtures 默认 light 的源代码没有改动；本轮正常 native-design 未跑完，不能记录运行验收 PASS。
比较器 self-check 零差异，且 [单像素清单外 positive control](contracts/comparison-positive-control.json)
在 metadata/manifest/stability 检查均通过时正确拒绝，不以 Source 红线代替截图回归。

## 停止与独立处置评审

执行停止规则②：截图跨作业基线出现清单外漂移，因果尚未认证。停止审美轮，不启动 S03，也不继续新 GUI 作业。
本轮保留 build/检查/冷启动已完成结果及失败作业，不重派 round 0/1 或已完成的 round-2 作业。
最高档独立评审只核对失败证据、回滚、停止、红线与如实披露；不把处置合规当作视觉 PASS。
未得到用户新的基础链路处理指示前，不恢复审美迭代；不请求 PR 或合并。

### 独立评审结论与逐字处置

[review-2.json](review-2.json) 已完成，观察到的回滚归档头为
`e775a5be32c9fcc9da2848c714ff627a358ecfe4`。评审独立核对 88 张原 PNG，未重跑 GUI 或契约作业。
处置合规仅限本地可核对范围，不等于视觉 PASS 或完整契约通过；S02 撤回，round 2 不计完成，仍余 18 轮。

**S02-F01／P1 原文：**

> composer-dark 的 before/after 在相同已记录机位、fixture、语言、字号和有效外观下有 376604 个可见变化像素，全部属于不允许变化的 preview，bbox 为 [0,0,760,500)。独立零容差白底合成重算与归档比较一致。11 个 inspector 场景受控、单侧双跑稳定、构建和 portable 通过都不能抵消这一契约失败；本轮视觉 FAIL、交付不可接受。

处置：维持已执行的 spacing 6pt 回滚和停止规则②，保留失败及撤回 after，不交付 S02、不启动 S03。
视觉阻断未解除；不扩大允许区、不忽略 RGB 差异、不挑选替代截图。窗口 tint 仍只是未认证假设。

**S02-F02／P2 原文：**

> gates-v1 将 PerchSourceRevision 的 git describe 字符串 v0.8.1-283-g92b718d5 与完整候选 SHA 比较。5/5 冷启动已完成且第一条 passed/数量断言成立，随后这条身份格式断言必然失败，原作业 exit 1；正常 native-design 调用位于该断言之后，未执行。不能把已完成子步骤包装为整体 gates PASS，也不能背书系统外观跟随、Settings 覆盖的本轮正常运行验收。

处置：保留 gates exit 1、native-design 未执行与完整契约 `NOT_PASSED`。完整 Git SHA 与 bundle describe stamp
分开记录；本轮不改测量／CI、不补跑或重跑，正常运行覆盖缺口未解除。基础链路处理须另获用户指示。

**S02-F03／P2 原文：**

> before-v1 的 --build-host 间接调用 --build-only，却复用既有默认 host app 路径，正确触发 CLI 拒绝。内层参数校验 exit 2、外层作业 exit 1，manifest comparisons 为空，0 张有效截图。before-v2 改用新的作业隔离 app 路径并显式使用 canonical Node helper，取得 22 场景双跑成功；旧失败未被抹除。

处置：沿用已完成的 v2 调用修正；v1 仍归类为 CLI 调用契约失败，而非产品编译或 runner 会话失效。
保留 v1、旧 app 与 v2，不删除旧产物、不重派完成作业、不操作权限或服务。

**S02-F04／P3 原文：**

> README 的 before-v2 起始时间为 16:42:06，而发布的原作业日志首行是 start=2026-11-18T16:42:03+08:00，相差三秒。结束时间、代码头、清单 hash、比较数量和 exit 均吻合。本评审采用日志的 16:42:03 作为记录起点，不把说明与原记录声称为完全一致，也不将这项小差异误作额外取证结论。

处置：已按原作业日志将本报告的起点纠正为 16:42:03；上述引文与评审 JSON 保留评审时快照。
原日志、diff 与截图均不改写，不为三秒文档误差重跑截图或构建。

父代理归档只修正文档并加入评审与发布扫描记录，不修改原 PNG、manifest、作业／构建日志或 diff。
评审的 522 文件摘要包含修正前的 README，属于评审时快照，不作为文档修正后的整体摘要。
最终归档仍是本轮单一 conventional commit；实际最终 SHA 由会话及外部 handoff 提供，不冒充新测试头。
最终归档的远端核验曾遇到 `OpenSSL SSL_connect: SSL_ERROR_SYSCALL`，Git exit 128；
发生于该次额外 amend／push 之前，现场与原证据保留。只按原 remote／认证方式普通重试，
未关闭 TLS 验证、调整凭据／权限或重启服务；此传输伪影不改变本轮视觉 FAIL 与停止状态。
归档发布扫描见 [完整发布树记录](contracts/public-source-stop-tree.log)：4888 files／0 findings；
文本模式扫描不代替图像隐私、未知凭据格式或授权审查。

原始回收证据保留于 `$HOME/code/_evidence/style-loop-round-2-20261118/raw/`。
发布副本只脱敏路径；PNG 字节与 hash 均保留；失败 v1 见 [原作业记录](contracts/before-v1/style-r2-before-v1.log)。
