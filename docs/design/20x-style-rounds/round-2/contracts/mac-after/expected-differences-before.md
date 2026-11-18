# Round 2 预期视觉差异清单

日期：2026-11-18。候选：S02。产品基线：`0a83a8d01c31e904d7952af4cacea2b88173aa1d`。
单一区域：`ChangesInspectorView.header`；不改变 inspector 的宽度、内部辅助道结构或内容。

## 假设

英文 `Current workspace diff` 在固定主窗口 fixture 中被截断，是标题与计数、
固定尺寸的返回/菜单/关闭控件及水平留白竞争宽度。仅压缩 header 的非内容水平留白，
为完整标题让出宽度；保留文字字号、计数内容、控件尺寸与行为。

## 允许差异

- 英文 inspector 标题完整显示，不以截断计数、缩小文字、隐藏控件或扩大 inspector 为代价。
- header 内标题、计数和相邻控件的水平位置随留白收紧而改变；中文也只允许同一 header 内的水平变化。
- light/dark、中文/英文、14pt/18pt 的代表场景使用同一 header 修改；header 高度与控件尺寸不变。

## 必须不变

- header 之外的文件行、文件内容、reader、composer、toolbar、sidebar、查找栏与滚动位置逐像素不变。
- 三个既有 preview 全部逐像素不变；不新增 preview 或验收页面。
- Fill/Stroke/Elevation token、单一系统玻璃、平面中性 sidebar 选中与 inspector 留白分隔不变。
- 系统外观跟随和 Settings 覆盖不变；验收与 preview 默认仍为 light。

原有 18 场景之外只补主窗口英文 dark、英文 18pt light/dark、中文 18pt dark 四组组合；
补充驱动复用原 `capture-style-loop.py` 与相同 offline fixtures，不改变产品默认值。
像素允许区域将在 before 图中固定并归档，随后才改产品；不根据 after 图扩大区域。
出现清单外差异、标题仍截断、计数截断或重叠时回滚本轮产品修改，不扩展到其他区域。
