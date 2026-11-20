# Round 8 / I02：静态窄窗截图几何（修改前清单）

本轮仅截图基建，用户 2026-11-20 授权持续自主推进。源代码产品零改动；正常功能验收、性能与 CI 门槛零语义变化。

- 唯一修改：截图专用 StyleCapture helper 增加 opt-in `PERCH_STYLE_CAPTURE_SIZE`，缺省保持原内容尺寸；一个新增截图脚本只在本次自行启动的既有 native fixture 中使用该参数。
- 用既有静态 capture fixture，固定 836×900，原固定位置与既有语言／外观／字号变量保持。无需 AX、不请求权限、不走录屏 fallback。
- 相比旧正常验收图，静态模式本就 stopped，不认证其与旧动态状态逐像素相等；原 685 像素稳定性 FAIL、旧 review 与 round7 FAIL 保留。
- 本轮新同头 A/B 必须同状态、同机位、同驱动；PNG 字节及全窗口 RGBA／整数白底 visible／alpha 零差异。
- 原ready是布局就绪，不提前认证compositor已静止；修改前固定5秒补证已验证中文light14pt原PNG及RGBA／visible／alpha全0。新脚本与已实测副本逐字一致，在ready后同一Node命令前固定等5秒，不挑帧、改玻璃或调整容差。八组合／正常矩阵与gates仍须本轮实际完成。
- 普通 34 场景不传新尺寸参数，须维持原 fixture 默认尺寸；完整正常 Mac gates 与5冷启动实际通过后才能闭合契约。
- 既有窄窗遮挡不称为修复，不改布局／材质／token，不新增 preview／fixture，不进入 S04/S05。

任何新清单外差异、权限／来源／机位异常或零容差失败，立即阻断恢复与计数。当前未完成、仍余14轮。
