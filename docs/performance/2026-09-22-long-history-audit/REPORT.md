# Perch 长会话阅读审查 — 2026-09-22

基线 `b66181a577d9612f30bd8441334c16bea0557e06`；分支 `codex/perch-long-history-audit`。仅本地独立工作树，未推送、合并、发布，也未操作真实会话。报告逐轮补充。

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
