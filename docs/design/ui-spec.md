# UI / 交互规范

> Perch 界面与交互的**唯一约定来源**。凡是"两个地方长得不一样、动得不一样"
> 的问题，先在这里定一条规则，再改代码；代码里值得复用的做法，回写成规则。
> 做法移植自 ccgui 的 ui-ux-spec（MIT），内容按 Perch 实际落地。

## 维护约定

- **谁改谁更新**：新增或修改用户可见的交互反馈、基础组件视觉、动效时长时，
  在同一个提交里更新本文对应章节。
- **规则要能指到代码**：每条规则写清文件和类型名。文档与代码冲突时以代码
  为准，并立即修正文档（或改代码 + 补充说明）。
- 规则来自真实问题，不预先发明；同一条规则第二次被违反时才值得新增。

## 动效

- **展开/收起做高度过渡，推开下方内容，不允许条件渲染直接闪现。** 统一走
  `WorkbenchDisclosureContent`（`Sources/AgentWorkbench/WorkbenchGlass.swift`）：
  250ms easeInOut clip 高度；收起动画结束才卸载内容；记忆展开状态的行
  恢复时不重放动画。详见 `docs/design/disclosure-animation.md`。
- **列表行不用 opacity 淡出**，只裁切高度（淡出会在下方内容上留一帧残影）。
- **动效可降级**：所有过渡在 Reduce Motion（系统或会话覆盖）下直出。

## 表单与问答

- **单选圆形标记、多选方形标记**（`KimiQuestionView`、`NativeInteractionView`）。
- 单选答完自动推进到下一道未答题；中间多选题「确认本题并继续」；最后一题
  由底部「提交回答」统一提交；自由回答输入时不自动推进，已答摘要可「修改回答」。
- **禁用要看得见**：排队调序按钮在两端禁用但保留位置（置灰），不用隐藏代替。


## 状态条

`ConversationActivityBar`（`Sources/AgentWorkbench/ConversationActivityBar.swift`），位于正文与输入框之间。

- **一行、透明、恒定高度。** 所有状态共用 `ConversationActivityBar.height`（32pt），不加整条玻璃、卡片或底色；
  开始运行、等待确认、断连或失败都不改变正文视口高度。注意力只体现在颜色和显式按钮上。
- **只有真实执行才转圈**（`ConversationActivity.animates`：在线、运行中、无待确认、未在停止）。其余状态用
  SF Symbol：断连 `wifi.exclamationmark`、待确认 `hand.raised`、停止中 `stop.circle`、本轮结束
  `checkmark.circle`、结束但有需关注结果 `exclamationmark.circle`。
- **信息分主次。** 当前动作（标题；通用标题附工具目标，如「正在执行命令… swift build」）> 用时 > 计划步数 >
  编辑行数 > 并发工具与后台任务。窄窗口用 `ViewThatFits` 从最低优先级开始收起，用时与标题保留；
  详情弹窗始终列出全部信息。单个运行中的工具已由标题说明，不再显示「1 个工具」。
- **待确认、失败、断连必须有显式入口。** 断连 →「重新连接」（详情与提示中给出最后的连接错误）；
  待确认 →「查看」（跳到待处理项）；本轮结束后仍有需关注的工具结果 →「查看」（打开详情）。
  运行中出现的需关注结果只加橙色计数，不改当前动作的颜色。
- **Goal 保留执行反馈，断连提示不重复。** Goal 头部保留实际执行的小转圈和目标自身状态，状态行高度固定，
  不随一轮开始或结束变化（`GoalHeaderBar.status`）。会话可见时，断连只在状态条提示，
  不在底部再放一行（`NativeAgentView`、`KimiWorkspaceView`）。
- **可达性。** 主按钮可悬停、可键盘激活；VoiceOver 值包含标题、工具目标、需关注计数与步数，
  不含每秒变化的时钟。操作按钮保留可见标题，用 hint 说明去向。
- 验证：`check-host-lifecycle.py` 的 `activity-bar` 阶段在宽/窄、浅/深色与六种状态下检查高度、
  视口不变以及「查看」「重新连接」可点击。

## 返回最新

`ReturnToLatestButton`（`Sources/AgentWorkbench/ConversationScrollControls.swift`）。

- 只有 32pt 胶囊悬浮在正文上：玻璃、描边、悬停色与命中形状共用一个 `Capsule`，不预留页脚；
  显隐与「有新内容」文案变化都不改变视口或阅读位置。Reduce Motion 下宽度变化不做动画。
