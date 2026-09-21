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
