# Round 1 预期视觉差异清单

区域只限主窗口 settled reply 的操作行，假设是 `RecapActionButton` 让 label 使用固有尺寸后，
原生 hosting 的 `fittingSize` 能覆盖 18pt 的实际文字宽度。

取证边界：未独立认证本清单首次写入的时间；实际截图与清单一致，不等于独立证明
清单先于原截图写入。这里保留原单一区域与允许差异，不按截图结果扩大范围。

允许的差异：

1. `main-large-type` 中 `Re…` 变为完整的 `Recap`；操作区只增加实际所需宽度。
2. 相邻 copy/quote/regenerate 图标保持原位置关系，不重叠、不换行。

必须保持不变的差异：

- 默认 14pt 的 `main-light`、`main-dark` 应与 round 0 基线逐像素一致。
- light/dark 的颜色、玻璃、sidebar、inspector、composer、查找栏及其他 preview 不得出现
  本轮清单外的视觉差异。
- 已采集代表场景的本轮操作标签不截断；18pt 的操作标签与图标不重叠。
  英文 18pt 全主窗口、18pt dark 和其他窗宽未覆盖；S02/S03 既有截断不在本轮范围。

若默认字号出现像素变化，或任何其他区域出现清单外差异，回滚本轮 modifier 而不是扩大修复面。
