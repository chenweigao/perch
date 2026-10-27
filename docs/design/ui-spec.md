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

## 正文刻度

- **正文尺寸、行高与间距只取自 `ReplyStyle`**（`Sources/AgentWorkbench/ReplyMarkdownView.swift`）：
  16pt 正文 / 26pt 行高 / 12pt 段距，680pt 阅读栏；H1 20pt，其余标题与正文同号，靠字重和留白分层。
  视图里不写本地字号或间距数字。
- **两种渲染共用节奏**：块间距统一走 `ReplyStyle.blockSpacing`，代码卡片、引用、列表分别用
  `ReplyStyle.Code` / `Quote` / `ListLayout`；SwiftUI 行与原生缓存行必须从同一组常量取值，
  流式结束切换渲染时不得跳动。详见 `docs/design/visual-refresh.md`。

## 窗口框架

`WorkbenchSplitController` / `WorkbenchDetailController`（`Sources/AgentWorkbench/WorkspaceSplitView.swift`）。

- **一整块通透的磨砂底板。** `WorkbenchWindowBackdropView` 使用系统 sidebar 材质与 behind-window 模糊，
  仅叠加 8% 的语义 window-background 色；窗口背景透明，材质保持 active，跟随浅深色外观。
  侧栏和工具栏共用底板；侧栏不再单独加玻璃外框、描边或阴影。
- **内容浮在底板上**：对话卡片与检查器使用 `WorkbenchTheme.Radius.panel`（20pt），
  不透明内容底色、发丝线和独立 AppKit 阴影层；阴影不能放在裁切内容或 SwiftUI 管理的图层上。
  裁切内部页面，终端与滚动内容不越过圆角。
- **正文为主，检查器为辅助浮层。** 画布与对话 hosting root 始终保留；宽窗口中对话卡片避让侧栏和检查器，
  面板之间露出 12pt 底板；检查器顶部比正文再下沉 12pt，优先高度 680pt，底部至少留 24pt，不能铺成等高的第三列。
  1440pt 窗口采用左栏 304pt、主卡片 776pt、右浮层 312pt；空间不足以保留 600pt 主卡片时，右浮层才覆盖内容。
- **标题锚定窗格，阅读栏居中**：工具栏标题距卡片左侧 24pt；正文、活动条和输入区在卡片当前可用宽度内居中。
  右栏展开或关闭、左右侧栏缩放后必须重新居中，不能把正文固定在左边。对话和草稿宿主保持挂载。
  工具栏放在统一底板上，正文卡片从窗口顶部 56pt 开始；hosting root 不重复应用标题栏安全区。
- **工具栏按钮一组胶囊**：改动、文件、任务面板和会话菜单共用一个玻璃胶囊，单个按钮不再各带底。
  机器和 Agent 只在输入框底部显示，标题旁不再重复。
- **模型必须可见**：输入框底部明确显示实际模型名及独立的思考强度选择器，不能用 Agent 名替换模型名。
  运行环境作为次级信息；控制行不再给每组文字各套一层胶囊。窄窗口先将辅助控件移到第二行，保留模型与发送按钮。
- **输入文字与正文对齐**：正文最大 680pt，输入框外壳最大 704pt，内部 12pt 留白；
  两者共用中心线与文字左缘；窄窗下正文最少保留两侧 24pt，输入框两侧 12pt。外层继续使用系统 Liquid Glass。
- **检查器**：默认 312pt，可调范围 280–400pt；44pt 文件行、14pt 文件名、16pt 面板标题，完整路径和 Git 状态按需查看。
  选中文件名放在差异上方，普通文本差异只显示 hunks；完整补丁在文件审阅窗口保留。

## 侧栏

- **一套行几何**：导航、分区头、项目、会话共用 `SidebarMetrics`（`Sources/AgentWorkbench/SidebarMetrics.swift`）
  的图标列与内边距。导航 36pt；会话行最小 44pt，长标题可换成两行（约 54pt），离线或待处理状态继续向下展开，不能固定高度裁掉标题；分区标题从图标列开始。
- **项目子会话图标在项目图标正下方**（缩进 `childIndent`），标题与项目标题对齐。
- **分区头一种样式**：`SidebarSectionTitle`（12pt 半粗，62% 墨色，计数在后，箭头在后）。
  置顶等分区头不能淡到像禁用；置顶的「+」保持实心控件。
- 侧栏直接绘制在整窗半透明底板上；仅窄窗口覆盖正文时补同款底板，避免文字叠加。
- 默认宽度 304pt，可调范围 280–400pt；顶部搜索与新建使用图标按钮。
  初次使用默认显示最近会话，已有项目分组偏好继续保留，工作台、待处理、全部会话与任务组入口可用。
- 会话标题 14pt，图标 14pt；时间与运行状态保留稳定空间，hover 不得临时挤压标题。置顶和归档通过会话上下文菜单保留。


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
