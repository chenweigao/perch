# Perch 长会话阅读审查 — 2026-09-22

**交付：2 项最小修复；缩放候选撤回。消息覆盖和多条原生交互通过，但仍未达到长历史流畅度验收，不能宣称卡顿已解决。**

基线 `b66181a577d9612f30bd8441334c16bea0557e06`；分支 `codex/perch-long-history-audit`。仅本地独立工作树，未推送、合并、发布，也未操作真实会话。已于第 7 轮结束：第 5–7 轮连续没有找到新的可行动问题。

## 开始前检查

- 阅读门户 domain/worktree 规则、Perch AGENTS.md、构建说明、既有 viewport/scroll 报告。Perch 不在门户 workspace.yaml 子仓库映射中，依据它的 origin/HEAD 和 main 历史确认 canonical main。
- `git fetch origin main` 得到 b66181a；原 main 工作树干净，保留在原 HEAD 5e22a94。已有 9 个其他工作树不复用。
- 门户 main 已有其他任务改动，本轮不修改。
- Mac arm64，18 GiB；Swift 6.3.3，Release/-O。系统 CLT 私有 ManifestAPI 版本混装；使用仓库 prepare-local-swiftpm.sh 建立工作树本地副本，无系统工具链改动。
- 初次系统工具链构建失败；第二次构建因新增 fixture 检查恰逢编译而报 source modified，保留日志，后续源码冻结后构建。Core 已独立编译并检查。
- 复制的 Baseline.app 两次 SIGKILL 且没有 started/result，UI 启动也超时；签名静态验证有效。原 build/Navigation Preview.app 同一二进制随后运行成功。根因未确认，失败不计入性能对照。

## 对照约束与证据边界

Navigation Preview 使用生产 ConversationTranscript/ConversationScrollView，200 轮固定混合消息，500 个合成侧栏会话，缓存 8 个会话，1180×600 pt 根视图、600 pt 对话视口、700 pt 阅读列。每个进程独立的会话 UUID 不影响消息正文；fixture/source/dependency/二进制指纹存于 JSON。

计时为程序化滚动→主线程布局/显示提交，**不是硬件输入延迟或 compositor FPS，也不等同主观流畅度验收**。下行首次遍历和上行重读采用半视口步长；小步往返为 1200×12 pt。保留宿主包含已脱离视口但未淘汰的控制器，RSS 单独记录；RSS 波动不单独证明泄漏。

## 第 1 轮：前插旧消息丢失阅读锚点

触发：在固定 200 轮历史滚动至 y=1800，等待布局完成，再经 KimiConversation.prepend 插入 20 条旧消息。

确认：同会话 configure 重建 offsets，却仅在切换 session 时读取 restoreTarget。原生 document 的阅读行从原第 4 轮变成 text:older-10:0，行内偏移从 33 变成 8；消息数量 540。不是单纯滚动条比例变化。

最小修复：在同会话出现前插时，使用旧几何捕获消息 ID/行内偏移，待新几何可用恢复同一锚点；使用更新前的 contentOriginY 捕获。保留全量内容与既有分页路径。

新增测量只回答尚未解决的两个问题：前插是否保持精确锚点；限制宿主后的上下遍历 RSS 是否仍随访问持续增长。结果见 r01 的 anchor-detail/result/supervisor。

验证：前插后保持同一消息、偏移 33→33 pt；前后均观察完整 200 轮与末尾，文档高度均为 106745 pt。8 次切换完成，保留宿主最大 20。完整 Release App build/sign 与 WorkbenchChecks 通过，真实 SSH 检查跳过。真实隔离 Reading Preview 已从可见分页按钮加载至全部 60 轮，旧第 21 轮仍在视口；回到最新可见。

| 固定回放指标 | 修复前 | 修复后 |
| --- | ---: | ---: |
| 首次向下半屏步进 p95 ms | 32.67 | 31.21 |
| 向上重读半屏步进 p95 ms | 33.75 | 33.58 |
| 12 pt 往返步进 p95 ms | 3.41 | 3.31 |
| RSS 开始 / 下读后 / 上读后 MiB | 121.3 / 152.0 / 154.4 | 121.0 / 152.3 / 155.1 |

本轮修复的是锚点正确性，不以这组差异声明性能加速。向上重读仍有约 34 ms p95 的成本。

补测：从底部进入上方历史再前插，activity:tool:only-197 保持且行内偏移 16→16 pt。一次通过 AX 点击屏外分页按钮后视口变为旧页首；该操作可能自动滚动按钮到可见处，不能作精准锚点失败证据。保留此观察，并用不经点击的底部前插回归和可见按钮检查区分。

原始大体积 reading-trace 和编译日志留在本工作树 `.local/long-history-audit/`；本目录保存摘要结果、样本及监督器记录。

## 第 2 轮：回读剩余成本与生命周期审查（无产品改动）

触发：第 1 轮固定全量回放上行 p95 约 34 ms，宿主数已有限制。检查 controller/viewport/observer/retire 的实际路径并采样 5 秒。

确认：当前 mounted/retained 分离，保留范围为可见行前后各 12 行；淘汰对象经过单一主线程退役队列，回调取消，weak 观察者随 document 销毁移除。上行 RSS 增长约 3 MiB，单次短跑不证明长期稳定。采样看到 sizeThatFits、SwiftUI 布局和 Markdown 解析，采样窗口也包含切换；不能将包含关系相加为热点占比或可得加速。

决策：未找到有证据支持的最小性能修复；不添加解析缓存、预加载或新抽象。保留完整 sample 于 .local/long-history-audit/r02-profile。此轮计一次无新可行动问题，后续正确性审查继续。

## 第 3 轮：缩窄列后的轻微锚点位移（候选撤回）

触发：在同一 200 轮混合历史先执行搜索以测量远近行，再到 y=1800，700 pt 阅读列缩至约 420 pt。同一消息行内偏移 165→168 pt。会话切出再返回保持缩窄后的偏移。

确认：当前实现不会为同会话宽度更新保持精确像素锚点。更深原因尚未完全确定；不能只根据 3 pt 的差异断言文字行本身漂移同样距离。

尝试：在 sizeThatFits/随后 setFrameSize 两种入口捕获已有阅读锚点，等待 committed width 后恢复。出现过 165→165 pt 的成功，但两次最终复验一过一败（r03-width-order-1/2）。**撤回全部宽度候选**，未把偶尔成功当成修复。失败结果、候选 patch 均保留。

验收同时揭示了新挂载消息的搜索选区偶发丢失，目标行始终还在 mounted rows。转入下一轮单独处理，保持本轮未解决状态。

## 第 4 轮：新挂载搜索结果未建立原生选区

触发：在未完整读过的 200 轮历史依次查找第 196 轮代码 fixture-195、第 6 轮标题、首轮表格“中文换行”。修复前出现标题/表格目标行已挂载而 selected text 为空，见 r03 的独立失败记录。

执行路径：PerchRevealConversationHit → ConversationDocumentView.reveal → mount/measure → 下一主线程队列遍历 ReplyTextView。仅把动作延后一队列不能保证新 NSHostingController 的原生文本树完成布局。

最小修复：在既有异步回调里对目标行执行一次 layoutSubtreeIfNeeded，再使用原来的查找、选区和 scrollRangeToVisible。不加重试、缓存、预加载或新的搜索语义。

验证：去掉诊断日志后的最终候选连续 3 个独立进程、9 个代码/标题/表格查询全部建立正确原生选区；完整 200 轮阅读、末尾、保留宿主和底部进入后的前插回归通过。缩放候选已全部撤回，interactions 模式仍保留严格 1 pt 断言，用来复现未解决位移；search 模式只独立验收搜索，不隐瞒 interactions 的失败。

同 fixture 的 b66181a 对照与最终构建结果补充于收尾段。

### 最终同 fixture 短对照

使用最终 Navigation fixture 分别重建 b66181a 生产源码与候选，基线仅补同样的 TRANSCRIPT_CHECKS 观察接口。fixture/Package.resolved SHA256 一致；生产 source SHA 与二进制 SHA 分别记录。过程脚本保存在 compare-matched.py.txt，临时源码由 finally 恢复。构建和计时分离。

| 指标 | b66181a | 候选 |
| --- | ---: | ---: |
| 首次向下 p95 ms | 30.79 | 32.21 |
| 向上重读 p95 ms | 35.07 | 33.58 |
| RSS 开始 / 向下 / 向上 MiB | 120.9 / 145.4 / 147.3 | 120.9 / 143.0 / 146.4 |

两者均全覆盖 200 轮及末尾，文档高度一致、宿主数有界。这是短对照，不提供统计显著加速或主观流畅度结论。b66181a 的同 fixture 搜索在这一次也通过；原选区问题是间歇性问题，不是每次跳转都会失败。候选独立三次回归全通过。

最终完整 Release App build/sign 通过，Reading Preview 重新构建通过。生产改动仅为前插锚点与单目标行搜索布局；没有修改 Core、协议、消息解析语义或 Composer。

## 第 5 轮：富文本、流式历史、图片和展开状态（未发现新可行动问题）

实际 Mac UI，隔离 Reading Preview，无真实会话：

- 流式思考每 100 ms 追加时向上滚动两页，保持第 55–57 轮，随后一次观测 AX 与滚动条 0.9331948686621869 均未变化；回到最新后看到本地 TIFF 和第 299/300 条追加思考。
- 折叠 Thinking，向上越过多页到第 15–18 轮，再回到最新，仍为 Collapsed，图片重新可见。
- 最终二进制中展开工具详情，再切到富文本历史快速上 4 页/下 1 页，看到第 51 轮中文、列表、表格、代码原文；切回工具后依然 Expanded，无正文提示仍保留。
- 窄列后消息仍可读；精确 3 pt 偏移沿用第 3 轮未解决记录，不把“看起来没跳”当成像素断言通过。

这些是实际窗口控件、内容与交互检查，没有测量显示链路帧率；不宣称达到 Codex 的主观流畅度。本轮没有产品代码修改，也不再增加重复 fixture。连续无新可行动问题计数 1。

## 第 6 轮：输入、草稿与会话往返（未发现新可行动问题）

实际 Composer Preview 使用生产 MessageComposer，每 100 ms 刷新：通过 Unicode 粘贴核对“历史阅读时输入 draft-A\n第二行仍保留”，切至会话二输入 draft-B，回到会话一内容未变；Return 本地提交后显示完整两行且只清空当前草稿；会话二仍有 draft-B，Shift Return 后继续键入 line-2 成功。

CUA typeText 直接注入中文未完整送达，改用 Unicode 粘贴后读回完整；一次粘贴等待超时、一次 AX 切换报错，随后的 AX 读回确认动作实际完成。这些是工具交互限制，未当作生产 Composer 缺陷或 IME 验收。真实中文输入法 marked-text/候选组合未验证。

既有 Navigation roundtrip：20 次归档/分组/会话往返、60 次滚动间搜索更新，dropped_keystrokes=0；搜索模型更新到列表显示 p95 58.98 ms，会话内容 p95 34.68 ms。这不是同一窗口中真实 Composer 硬件键入与长历史滚动同时发生的测量；此边界保留。

ComposerChecks 可编译，但独立 .local/ComposerChecks 两次启动均 SIGKILL（第二次 shell 137），没有 PASS 输出，原因未确认，**不列为通过**；没有继续重复启动或修改安全设置。实际隔离输入窗口正常运行。

无产品修改，连续无新可行动问题计数 2。

## 第 7 轮：待释放宿主队列和持续资源使用（未发现新可行动问题）

仅新增 TRANSCRIPT_CHECKS 诊断：把退役队列与当前保留/挂载宿主分开记录。既有 soak 在 8 个预解码、每份 200 轮混合历史的会话间运行 180.14 秒，共 370 次切换、4440 次大跨度滚动、47 次模型搜索更新。

- 每约 10 秒采样：保留宿主 2–6，挂载宿主 2–6，退役宿主 0–5；这不是全过程峰值，不能把采样上界当成硬上界。完整连续阅读的逐步记录保留宿主最大 20。
- 同期进程 RSS 152.2–160.8 MiB，无持续上升趋势；开始前 112.0 MiB、结束 154.1 MiB、等待 500 ms 后 147.4 MiB。最后退役队列为 0。
- 切换 p95 59.25 ms；大跨度滚动 p95 49.22 ms，最大 72.86 ms。没有 >100 ms 步进，但 4439/4440 步超过 16.7 ms，不能作为流畅度通过。
- 正常退出、完整结果文件、监督器 passed。没有启动远端，也未操作任何正式 Perch 会话。

原实现的单一退役队列在该受控窗口没有显示持续积压；未增加释放调度或新的内存缓存。3 分钟/8 个缓存会话不证明整夜无限会话稳定。连续无新可行动问题计数 3，满足用户停止条件。

## 本地交付与验证边界

工作树目录：`perch-long-history-audit/perch`（位于工作区统一 `_worktrees` 目录），分支 `codex/perch-long-history-audit`。原仓库 main、其他任务工作树和门户已有修改保持原状；没有推送、PR、合并、安装或发布。

| 本地提交 | 内容 |
| --- | --- |
| aee26c0 | 前插旧消息保留阅读锚点；回归和初始对照 |
| 4c051fa | 有界宿主与剩余成本审查记录 |
| a4fd4d4 | 保留失败的缩放候选与证据，产品改动撤回 |
| fac99c4 | 新宿主先布局再设置搜索选区；同 fixture 对照 |
| fc38ca6 | 实际 Mac 富文本、图片、折叠与流式阅读验证 |
| 457389a | 输入草稿、会话往返和工具失败边界 |
| 本报告提交 | 退役队列测量、三分钟回放和最终收尾 |

完整 Release App build/sign、WorkbenchChecks、Navigation 各通过项目和实际 UI 观察分别见上文。WorkbenchChecks 真实 SSH 项明确跳过。ComposerChecks 两次 SIGKILL 无 PASS，不算通过。第 3 轮 interactions 严格缩放断言仍会失败，失败记录完整保留；不把搜索模式通过误写为整套交互通过。

### 未解决与下一步

1. 首次阅读、淘汰后重建仍有约 32–34 ms p95 的半屏布局成本；没有证明相比最新 main 有显著性能提升，也没有硬件输入到呈现帧率或与 Codex 同场景主观对照。
2. 缩窄列后的同一消息偏移仍可能 165→168 pt；撤回的候选没有解决晚到布局/几何变化的具体来源。
3. 同一窗口内完整生产 Composer + 200 轮历史 + 流式回复 + 真实滚轮/中文 IME 的联合验收未完成。现有输入窗口与导航窗口分别验证，不能合成为端到端结论。
4. 远端图片的慢加载/取消、整夜连续运行及超过 8 个缓存会话的资源行为未实测。未接触真实会话。

下一步最值得做的验证：把现有 200 轮固定历史与生产 Composer、固定速率流式尾部放在一个隔离窗口，用真实滚轮持续向上读并输入，采集显示帧间隔与主线程 Time Profiler；先确认尖峰是否与新宿主首次测量同步，再决定下一项最小修复。缩放问题同时记录 anchor ID/offset、contentOriginY 和高度回调时间，避免再凭单次成功调整恢复时序。

### 复现入口

先在该工作树执行 `scripts/prepare-local-swiftpm.sh`（仅本机混装 CLT 需要），然后：

```sh
export SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.local/swiftpm-libs"
scripts/build.sh
scripts/build-navigation-preview.sh
# 每个输出目录必须是新目录；以下均使用合成消息。
NAVIGATION_SCROLL_STEP_POINTS=12 python3 scripts/run-navigation-check.py reading --output .local/replay-reading --switches 8
NAVIGATION_ANCHOR_FROM_BOTTOM=1 python3 scripts/run-navigation-check.py anchor --output .local/replay-prepend
python3 scripts/run-navigation-check.py search --output .local/replay-search
# 保留的未解决缩放回归：失败是已知缺口，不是全通过入口。
python3 scripts/run-navigation-check.py interactions --output .local/replay-resize
python3 scripts/run-navigation-check.py roundtrip --output .local/replay-roundtrip
python3 scripts/run-navigation-check.py soak --seconds 180 --output .local/replay-soak
scripts/build-reading-preview.sh
scripts/build-composer-preview.sh
```

最后两个入口只构建独立 UI fixture；通过其 `build/Reply Reading Preview.app` 和 `build/Composer Preview.app` 进行实际交互。禁止把这些 fixture 的通过状态替代正式会话或远端协议验收。

收尾重新 fetch：origin/main 仍为 b66181a；与任务分支的 merge-tree 检查无冲突。所有本轮隔离预览进程均已退出。首次收尾提交被发布检查发现报告中的个人绝对路径；已改为可移植的工作树标识，未绕过检查。
