# Round 3 / I01：预写视觉差异清单

写入日期：2026-11-18；before 基线 `5a4478eb317dc50321fbe4c28c034beaf5d53ec1`。此清单在新 before 与代码修改前固定。

## 允许的单一修复

- 区域只限既有 Composer preview 捕获态的窗口背景，light/dark 都用既有 `WorkbenchTheme.contentBackground`。
- 既有 token 的 light 为白色；dark 为蓝石墨 `(0.122,0.133,0.161)`。不新建、改值或统一明暗 token。
- 原未固定的平台背景换成上述固定内容背景；其上原生 glass／文字抗锯齿由背景合成带来的颜色差异属于同一背景修复。
- 不允许文字、fixture 数据、字号、控件尺寸、间距、引用内容、计时计数、圆角、布局或窗口几何变化；不改普通非捕获态预览。
- Composer 的固定 content bounds 为 `760×500`、window origin 为 `(48,72)`；有效 before 后再按实际元数据固定像素允许区。

## 必须保持不变

- 13 个主窗口场景与其余七个既有 preview 场景：零可见像素差异，包括 light/dark、中英、默认／放大字号与查找／滚动场景。
- 系统外观跟随、Settings 覆盖、fixtures 默认 light、主窗口单一 Liquid Glass backdrop、原生 composer 与控件均不改动。
- 同一矩阵的 repeat-1/repeat-2 必须逐可见像素一致；after-A/after-B 两个独立作业的全部 22 场景必须逐可见像素一致，任何场景均无例外。
- PNG 原件不重采替换、不后处理；元数据／manifest 的 hash、机位、appearance、locale、large_type 必须验证。

## 失败处置

出现清单外变化或 after 跨作业漂移就不交付本轮、不计完成，按原停止／回滚契约处理。
旧 round 2 的 376604 像素失败仍保留；本轮不是扩大旧允许区或把旧 after 改判 PASS。
窗口 tint／壁纸只属未认证诊断候选，不把本轮可比性证明包装为系统颜色因果认证。
