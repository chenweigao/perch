# Round 4 / S02 预期视觉差异清单

日期：2026-11-18。本轮实际产品基线：`aad604b9ce5294b52951f189b3895b69edd12f31`。
区域仅限 `ChangesInspectorView.header`。这是 S02 的新轮次，不恢复 round 2 的撤回候选或旧截图。

## 单一假设

英文 `Current workspace diff` 与中文标题在 inspector header 中和计数、返回／菜单／关闭控件及四段水平留白竞争空间。
只把外层 HStack 的6pt间距收回为0，为完整标题让位；内部标题／计数6pt间距、Spacer最小4pt、字号、控件尺寸、padding与行为均不变。
不增加独立卡片、边框或阴影，不改 inspector 宽度或 reader/composer 联动布局。

## 声明内变化

- inspector header 的标题、计数和相邻控件仅发生水平位移；英文默认／放大代表场景标题须完整，不以计数截断、字体缩小或隐藏控件换取空间。
- 同一处修改用于中文／英文、light/dark、默认／放大字号；header高度与控件尺寸不变，无重叠。
- 允许区固定为PNG半开矩形 `[1218,44,1530,96)`，仅11个打开changes inspector的主窗口场景使用；完整列表见 `allowed-regions-before.json`。
- 机位必须由本轮新before验证为原1536×900、backing scale 1及同一fixture；不因after差异移动机位或扩大允许区。

## 声明外零差异

- header以外的文件行、阅读内容、composer、toolbar、sidebar、查找栏、滚动位置逐像素不变。
- 其余主窗口状态与三个既有preview逐像素不变，包括round3已固定的Composer light/dark背景。
- 不改Fill/Stroke/Elevation或圆角token；系统外观跟随与Settings覆盖、默认light的验收/preview fixture不变。
- WorkbenchCore、其他Sources、测量/CI语义零diff；不碰用户真实连接、凭据、会话或权限。

新before/after均通过PerfRunner，各22场景双跑；清单外差异、任何相机/fixture漂移、标题或计数仍截断/重叠均不得记完成。
出现以上失败时撤回本轮产品，不修改旧round2/3证据、不挑选截图或把问题顺手扩面。
