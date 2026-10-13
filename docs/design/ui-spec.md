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
- **数字变化用里程表滚动**：状态条计数用 `.contentTransition(.numericText())`
  + `.animation(_:value:)`（`ConversationActivityBar`），不换行不推挤布局。
- **动效可降级**：所有过渡在 Reduce Motion（系统或会话覆盖）下直出。

## 流式渲染

- **直播回复逐帧揭示**（A1）：存储文本始终完整，`StreamReveal` 游标只决定
  可见尾巴；240ms 滞后上限、大批积压整体呈现、整段替换不动画。规则细节见
  `docs/STREAM-REVEAL.md`。
- 代码块文本按源码缓存，重解析不重建未变块（`ReplyTextAttributes.code`）。

## 表单与问答

- **单选圆形标记、多选方形标记**（`KimiQuestionView`、`NativeInteractionView`）。
- 单选答完自动推进到下一道未答题；中间多选题「确认本题并继续」；最后一题
  由底部「提交回答」统一提交；已答题折叠为已选摘要。
- **禁用要看得见**：排队调序按钮在两端禁用但保留位置（置灰），不用隐藏代替。

## 输入框

- **粘贴与拖拽同构**：图片进附件管线；本地会话的非图片文件在光标处变
  `@"path"` 引用；远程会话本地文件只能作为附件上传（本地路径对远端无意义）。
  实现：`DraftTextView.readSelection`（`MessageComposer.swift`）。
- **↑↓ 历史召回仅从空草稿起步**（与 ccgui usePromptHistoryNav 语义一致）：
  多行编辑中 ↑ 永远先移动光标；↓ 过头恢复空草稿。`ComposerRecall.swift`。
- 长文本粘贴折叠为 `@paste("id")` 令牌，发送时展开（`DraftPaste`）。

## 状态呈现

- 活动条计数（步骤/工具/运行中/+−行数）在轮次结束后冻结保留，不自动消失；
  新一轮带来新数据时再更新。
