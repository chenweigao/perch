# S04 预写视觉差异：只提高暗色 quiet 的前景层级

日期：2026-11-19。基线 `ec3372c8d81dd5844bbfc4bdf5d973be80ef2bb4`。本清单在新 before 及产品写入之前创建；原件摘要随 before job 一起保存。

## 唯一预期变化

1. dark quiet 从 `(0.520,0.550,0.610)` 到 `(0.540,0.570,0.630)`，三通道同增0.020。暗色时间戳、分组／会话计数、辅助标签、空态说明，以及同 token 的箭头、离线图标等辅助前景／细线略变清晰；不新增视觉元素。
2. 所有同 token 引用一起列入预期，包括主窗口、Workbench／Sidebar／Composer 三个既有 preview；不能仅声称文字改变而隐瞒已知同 token 图标变化。实际可见引用在新 before 目视及源调用索引中对应记录。
3. light、正文 ink、accent、语义色、Fill／Stroke／Elevation token、glassUnderlay 及材料参数全部不动；位置、尺寸、字体、行高、文字内容、菜单选项／绑定、scroll／选中／inspector 状态均不动。
4. token 对画布的算术对比约4.7277→5.0505；light 对白约5.0968及正文对画布约11.4041不变。这是 token 模型计算，不是显示器、玻璃／compositor 光学实测或审美批准。

## 先冻结再比较

- 复用34场景：主窗口13、Workbench16、Sidebar3、Composer2；每场景两次同机位。同一合成 fixture 的有效明暗、语言、xxxLarge及首次使用参数都固定。
- 19个light场景不允许任何全窗口 RGBA／白底可见像素或 PNG 字节变化。
- 15个dark场景的前景掩码只从**新 before**构建：RGB八邻域边缘，按 Chebyshev 半径3膨胀，并加入与原 quiet 的量化 RGB `[133,140,156]` 每通道相差不超过3的纯色前景。规则与机位先写入 `color-geometry-before.json`；实际掩码／原PNG摘要在产品写入前另冻结，不读取after生成或扩张掩码。
- 掩码外 RGBA及白底可见像素容差为0。掩码内也只允许中性提亮：alpha逐像素不变；原RGBA与白底RGB的每通道增量均在0–8，三通道增量跨度不超过3。不允许变暗、换色、内容／几何移动或大面积背景漂移。
- 主窗口dark和Workbench-dark须出现实际前景颜色变化；其他dark fixture可因未展示quiet而零变化。双跑必须逐像素、PNG字节一致，不用裁剪、缩放、阈值或豁免掩盖不稳定。
- 同机位完整图为交付证据；放大／裁剪只作观察，记录原图摘要与坐标，不能代替原图或扩大认证范围。

## 不允许变化与失败处置

系统跟随、Settings明暗覆盖、默认light、单一玻璃、平面sidebar、留白inspector、同心外sheet与原生composer／控件均不改。出现上述清单外变化则撤回本轮，保留失败原图／回执，不在after后调大掩码、步进或规则；先区分产品差异与基建漂移，再按原停止规则处理。
