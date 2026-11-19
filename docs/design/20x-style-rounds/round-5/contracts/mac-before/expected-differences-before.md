# S03 预写视觉差异清单

首次写入日期：2026-11-19。真实产品基线：`566c0c3e449fa076adbee1d91a9002ddd561034d`。队列条目S03，单一区域为既有Workbench preview的header筛选器。

## 基线观察与单一假设

旧轮同机位原图与现行源码显示：英文Task Groups的当前值只剩ellipsis，Machine为`All…`；中文任务组当前值也为`全部…`。原队列只记录英文，并不表示中文已完整。两项原生Picker的130／120pt硬frame把标签与当前值压进同一上限，仅减外层10pt间距不会增加Picker内部宽度。

唯一产品假设：给任务组／机器Picker保留水平固有尺寸，并把原130／120pt改为最小宽度而非硬上限；不藏标签、不缩字、不改本地化文字、所选值、binding或菜单行为。预览状态Picker、外层10pt间距、控制大小、字体、padding、sidebar／workspace／dashboard几何均不改。

## 允许的差异

- 仅九个既有Workbench场景的header筛选器与相邻水平留白变化：中英×默认／放大×light／dark八组合，加既有首次使用light。
- 当前值应完整显示：英文`All task groups`／`All machines`，中文`全部任务组`／`全部机器`；两个标签保持可见，原生Picker与其箭头不得重叠。
- 筛选器需要的额外水平空间可使三个控件在同一header内向左分配；预览状态标签与当前值的内容／字体不得改变。Workbench标题不得缩短、移动或被遮挡。
- 固定允许矩形为PNG左上原比例半开`[544,48,1112,104)`，只适用于九个Workbench场景，参考图像1120×820／backing scale1。不得在看到after后移动或扩大矩形。

## 禁止的差异

- 九个Workbench场景的header以外RGBA与白底合成可见像素都必须零差异，包含workspace轮廓／背景、sidebar、卡片、正文、分组／会话行和首次使用空态内容。
- 其余十八场景（main十三、Sidebar三、Composer二）全窗口零差异；S01 Recap、S02 inspector、I01 Composer背景都不得变化。
- 不增preview页面或平台，不重开玻璃、sidebar、inspector、圆角、系统外观策略或默认light fixture方向；不改性能／CI语义或真实会话。
- 每矩阵27场景×2重复，54原PNG；重复必须PNG字节相同。前后必须同wrapper、机位、fixture、语言／字号／外观与精确源码头，清单外差异回滚本轮，不扩大允许区。

放大fixture是既有StyleCapture的`.xxxLarge`代表设置，不声称所有原生控制都变成18pt或任意窗口／文字长度均被认证。新的Workbench组合只扩充既有页面的回归截图，不是新preview设计。

新before未通过前不改产品；默认／放大、中英、light／dark实际截图和真实Mac gates／独立目视分别归档，不用静态源码代替运行认证。
