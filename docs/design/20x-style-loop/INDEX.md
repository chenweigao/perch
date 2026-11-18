# 样式美化循环索引

唯一工作分支：`style/loop-main`。与 `perf/20x-loop-*` 完全独立；不开 PR、不合并到
`main`，除非用户在 20 轮汇报点明确批准。每轮开始前同步 `origin/main`，每轮一个
conventional commit。只修改 macOS 主窗口、既有 preview 与主题 token；
`Sources/WorkbenchCore` 和 `Sources/` 其余目录保持零 diff。

## 当前状态

- round 0：基建与队列初始化，证据见 [round 0 报告](../20x-style-rounds/round-0/README.md)。
- round 1 / S01：一行产品修复、三层证据与独立评审已完成；限定范围 PASS，无新增 P1/P2 finding。
- round 2 / S02：视觉契约失败，产品候选已回滚；`composer-dark` 跨作业底色漂移，停止规则②触发。
- **已停止审美迭代**；不启动 S03 或新 GUI 作业。独立处置评审已完成：回滚／停止 PASS_LIMITED，视觉 FAIL、完整契约 NOT_PASSED；单轮归档已收尾。
- [停止总结](STOP-20261118.md)；不重派 round 0/1 或本轮已完成的作业，本轮未计完成。
- 距上次用户汇报还剩 **18 轮**；当前未到汇报点，未请求合并。
- 已裁决外观方向不重开；当前没有「提案-待批」条目。

## 样式候选队列

排序规则：契约违例 > 明暗不对称 > 排版层级 > 密度/留白 > 动效。每轮只取一个条目，
验证一个最小假设。「触碰已裁决方向」为「否」的条目才可进入自动队列。

| ID | 区域 | 基线观察到的问题 | 单一假设 | 预计视觉差异 | 触碰已裁决方向 | 状态 |
|---|---|---|---|---|---|---|
| S01 | 主窗口回复操作行 | 正文 18pt 时 `Recap` 被截成 `Re…`，违反放大字号不截断契约 | 操作行应给文字标签保留最小固有宽度，图标间距让位于完整标签 | 仅放大字号的操作标签恢复完整；默认字号不变 | 否 | 完成：限定范围独立评审 PASS |
| S02 | 主窗口 inspector 标题 | 英文默认宽度下 `Current workspace diff` 被截成 `Current workspac…` | 标题区可减少非标题控件的占位竞争，让完整标题优先显示 | 仅 inspector header 的标题与相邻水平留白变化；其他区域不变 | 否 | 候选撤回；截图基建停止，标题仍待修复 |
| S03 | Workbench preview 顶部筛选器 | 英文 1120pt 窗口中任务组/机器选项被截成 `All…` | 筛选器标签与值应共享更紧凑的固定标签间距，而不是截断当前值 | 仅英文 preview 筛选器文字与间距变化 | 否 | 待执行 |
| S04 | 主窗口与 Workbench preview 的暗色辅助文字 | 时间戳、分组计数等 quiet 文本在暗色画布上明显弱于 light 的相对层级 | 仅提高 dark quiet token 的明度，保持 light 与正文 token 不变 | 仅暗色辅助文字变清晰；无布局位移 | 否 | 待执行 |
| S05 | Composer preview 暗色容器 | 引用 chip 与外框在暗色下几乎融入背景，边界弱于 light | 仅提高 preview 暗色 stroke 的对比度，不改变 composer 尺寸或原生玻璃 | 仅暗色 preview 的引用 chip/容器边界变化 | 否 | 待执行 |
| S06 | 主窗口查找栏空态 | light/dark 下匹配模式、范围与 `无匹配` 的文字层级挤在同一弱色层，扫读困难 | 保持紧凑布局，仅区分选项与结果状态的 quiet/ink 层级 | 仅查找栏文字颜色变化；输入框与工具栏几何不变 | 否 | 待执行 |
| S07 | Sidebar 分区标题 | `置顶/最近会话/今天` 的 13pt、0.40 opacity 在两种外观下都偏弱，分区层级不清 | 小幅提高分区标题 opacity，保持字号、行高与平面中性选中样式 | 仅 sidebar 分区标题颜色变化 | 否 | 待执行 |
| S08 | Inspector 文件状态标记 | 文件名右侧 `M` 在 dark 中尤其难辨认，状态语义弱于文件名 | 文件状态标记使用可读性更高的 secondary 色，不增加背景 chip | 仅 inspector 文件状态字母颜色变化 | 否 | 待执行 |

密度/留白与动效基线暂未发现需要自动修改的独立候选；滚动跟随在静态基线中单独留图，
后续若修改该区域必须先证明差异清单不扩大。

## 轮次记录

| 轮次 | 类型 | 结果 | 三层证据 | 评审 | 距用户汇报 |
|---|---|---|---|---|---|
| [0](../20x-style-rounds/round-0/README.md) | 截图基建 + 队列初始化 | 18/18 场景双跑逐像素一致；8 条候选；无审美改动 | 契约、视觉、回归证据见轮次报告 | 见轮次报告 | 19 轮 |
| [1](../20x-style-rounds/round-1/README.md) | 放大字号标签契约修复 | `Recap` 恢复完整；其余 17 场景零像素差异 | Mac build、5/5 冷启动、WorkbenchChecks、portable 10/10；18/18 repeat 一致；未覆盖组合如实记录 | [PASS](../20x-style-rounds/round-1/review-1.json)，无新增 P1/P2 | 18 轮 |
| [2](../20x-style-rounds/round-2/README.md) | inspector 标题宽度契约修复尝试 | 主窗口差异受控，但 composer-dark 376604 个清单外像素；候选撤回、规则②停止 | before/after 各 22/22 repeat 一致；build/checks/portable/5 冷启动通过；gates exit 1、native-design 未执行；跨作业视觉 FAIL | [回滚／停止 PASS_LIMITED](../20x-style-rounds/round-2/review-2.json)；视觉 FAIL、完整契约 NOT_PASSED；4 条发现逐字处置 | 未计完成，仍 18 轮 |

## 可验证的续作锚点

- 当前产品证据头：`b96cfdfaa5308b2a2cd705f7e7ec209e4a82d55f`；S01 不重复改代码。
- `style-r1-capture-v1` 与 `style-r1-gates-v1` 已完成并归档，不再次派发这两项作业。
- 每次恢复先核对分支、HEAD、本索引及已完成结果，再从未完成阶段接续，不以代理口头状态推进计数。
- SSH 只做短状态查询；不再用长时间阻塞轮询等待 PerfRunner。作业仍通过原队列串行执行。
- 连续运行器修复与恢复记录不放入样式产品目录；本线程保持当前 provider，不隐式切换。
- 2026-11-18 持续目标保持 active；S01 独立评审完成通知已收到并核验，计数已由 19 更新为 18。
- S01 结果已写入 `round-1/review-1.json`；不重复委派。后续评审完成仍由 T3 唤醒，不阻塞轮询。
- S01 收尾提交：`0a83a8d01c31e904d7952af4cacea2b88173aa1d`；产品与真实测试头 `b96cfdfa` 零 diff。
- S02 基线为 `0a83a8d0`，同步主线为 `9ed2ac1c`；新增四组组合只用于既有主窗口 fixture 的截图回归。
- S02 before v1 被新 app 路径的 CLI 契约拒绝，0 张有效截图；v2 修正调用且 22/22 双跑一致，不清理旧产物。
- S02 清单与像素允许区均在产品修改前写入；只回收外层四个 6pt 间距，控件尺寸与行为不变。
- S02 测试候选头 `92b718d5` 已撤回产品修改；after 原图保留。回滚后的产品等同 `0a83a8d0`。
- 独立评审观察到的回滚归档头：`e775a5be32c9fcc9da2848c714ff627a358ecfe4`；不冒充最终归档或测试 SHA。
- 独立停止处置评审已完成，唯一写入 `round-2/review-2.json`；不轮询或重派。4 条发现已逐字处置，三秒起点误差按原日志修正；视觉阻断与正常运行覆盖缺口仍保留。
- 最终停止总结见 [STOP-20261118.md](STOP-20261118.md)；本轮最终归档 SHA 用 `git log -1 --format=%H -- docs/design/20x-style-rounds/round-2/review-2.json` 核对，完整分支头同时写入会话与外部 handoff。
- 基建停止优先于持续目标；后续恢复必须先处理跨作业 preview 漂移，不能继续审美队列或扩大允许区。
