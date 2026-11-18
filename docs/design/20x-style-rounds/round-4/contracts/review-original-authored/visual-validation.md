# S02 视觉验证

2026-11-18。before为`aad604b9ce5294b52951f189b3895b69edd12f31`，after为`4b64796633d4cee9db9ac10bbc1ea8b2f4ea4da1`。

## 可比较性

- 新after作业21:40:51开始、21:47:09终结，`.done`存在、末行`exit=0`；实际host binary SHA256为`491a4827a6ee270afcfde6f407fd4885938bcd1c1547d2917fa4a51586ff227a`。
- 前后均精确源码头、clean Mac checkout；同一wrapper、fixture、语言／字号／外观环境、window frame/content bounds/backing scale，ready/window元数据一致。
- 两矩阵各22场景×2重复，88张原PNG；before与after各22/22重复PNG字节相同。发布图像也与原件逐字节相同，仅文本home路径脱敏。
- [零容差比较](before-after-comparison.json)同时检查RGBA与白底合成可见像素；不把透明像素或近似差异忽略。

## 实际差异

| 场景 | 改变的RGBA／可见像素（各） | 半开bbox |
|---|---:|---|
| main-english / main-english-large-type | 1602 | `[1258,67,1482,81)` |
| main-english-dark / main-english-large-type-dark | 1626 | `[1258,66,1482,81)` |
| main-light / main-large-type / main-find / main-scroll | 1696 | `[1259,66,1482,80)` |
| main-dark / main-large-type-dark / main-find-dark | 1733 | `[1259,66,1482,80)` |
| 其余11场景（含三个既有preview的8场景） | 0 | 无 |

11个打开changes inspector的主窗口场景全部只在冻结`[1218,44,1530,96)`内改变；清单外RGBA与可见像素均0，没有移动/扩大允许区或挑选重复截图。
header以外的文件行、reader、Recap、composer、toolbar、sidebar、find内容与滚动位置不变；Composer preview light/dark背景亦零差异。

## 显式查看

- 查看[八组header前后对](../comparison/headers-before-after.png)：四个英文组合均从`Current workspac…`恢复为完整`Current workspace diff`，`2 files`完整、无重叠；四个中文组合的标题和`2 个文件`仍完整。
- 查看英文放大dark的完整after原图，以及[英文light](../comparison/main-english-full-before-after.png)／[英文dark](../comparison/main-english-dark-full-before-after.png)全窗口对：header高度、控件大小、reader／composer布局和S01 Recap不变。
- 查看英文Workbench原图：既有筛选器截断仍在，属于S03，不称全产品无截断。
- [派生图provenance](../comparison/provenance.json)保存每个裁剪的原PNG SHA256、固定半开矩形、3×nearest或原比例无重采样；派生图不是新的机位或交付原图替代物。

放大fixture与全局外观的认证边界见[回归观察](regression-observations.md)。视觉通过不等于尚未完成的Mac gates或独立评审通过；本轮仍未计完成。
