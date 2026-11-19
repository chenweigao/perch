# S09 预写视觉差异清单

首次写入日期：2026-11-19。新 before 产品基线：`2ded248b7f3d6993841b05c88b33f36add451a92`。单一区域为既有 Workbench preview header 的预览状态 Picker。

## 基线观察与单一假设

round 5 前后原图仍显示 `首次使用` 为 `首…`，现行原生 Picker 使用硬 `.frame(width: 130)`。唯一产品假设为该 Picker 添加水平 `.fixedSize(horizontal: true, vertical: false)`，将原 130pt 保留为 `minWidth`；不藏标签、缩字、改文字、当前值、选项顺序、tags、binding 或行为。

## 允许的差异

- 只允许十六个既有 Workbench header 筛选器及相邻水平留白变化：日常八组合＋首次使用八组合，各为中英×默认／xxxLarge×light／dark。首次使用当前值必须完整为 `首次使用`，日常仍为 `日常`；英文 fixture 中该既有状态字符串不在本轮改译。
- 原生 Picker 标签保持可见、箭头与文字无新重叠；状态完整显示所需空间可让三个筛选器在同一 header 内向左重新分配。S03 任务组／机器控件源码、文字、字号与内部宽度策略不改；其当前值仍完整。Workbench 标题不移动、缩短或遮挡。
- 固定原 PNG 左上半开矩形 `[480,48,1112,104)`，参考 1120×820／backing scale 1，仅用于十六个 Workbench 场景。该范围预留 header 内向左重新分配的空白，不含标题；不得看到 after 后移动或扩大。

## 禁止的差异与取证

- 十六个 header 外 RGBA 与白底可见像素均零差异，包括 workspace、sidebar、正文、日常会话卡及首次使用空态；其余十八场景全窗口零差异且跨作业 PNG 字节相同。
- 不增 preview 页、平台或真实数据；不改主窗口、玻璃、sidebar／inspector／圆角、系统外观／Settings／默认 light、性能或 CI 语义。
- 每矩阵 34 场景×2＝68 原 PNG，所有双跑字节、像素、机位、有效明暗、语言及字号 fixture 一致；before／after 使用相同 wrapper 和精确源码头。首次使用新增组合的原命令必须为 `-scenario 首次使用`，不得仅将日常图改名。
- xxxLarge 是既有代表 fixture，不外推为所有原生控制 18pt、任意 Dynamic Type／宽度、任意选项或完整 UI 交互认证；正常 native-design 的 view-cache 也不当完整 compositor 或审美批准。

新 before 与控制验证通过前不改产品；实际目视、Mac gates 和独立契约评审分别归档。清单外变化先回滚本轮，不扩大清单。
