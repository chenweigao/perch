# Style loop round 1：放大字号的 Recap 标签

日期：2026-11-18。候选：S01。代码基线：`1ae2d640`；实际构建与截图代码头：
`b96cfdfaa5308b2a2cd705f7e7ec209e4a82d55f`。类型：契约修复，不扩展审美范围。
状态：产品修改、三层证据与独立评审已完成，限定 S01 范围 PASS；未开 PR，未请求或执行合并。

## 单一假设与最小修改

`RecapActionButton` 的文字尺寸受原生 hosting 的 `fittingSize` 约束，正文为 18pt 时
按钮显示 `Re…`。只在原有 label 上增加 `.fixedSize()`，让固有宽度参与尺寸计算。
24pt 高度、原生按钮样式、颜色、圆角、composer、sidebar 与 inspector 均不修改。

改动文件：`Sources/AgentWorkbench/ConversationActivityBar.swift`。产品 diff 为一行。
[预期视觉差异清单](expected-differences.md) 在原截图作业之前已经写入，未在验收时扩面。

## 三层证据

### 1. 契约层

| 检查 | 结果 | 证据 |
|---|---|---|
| macOS `scripts/build.sh` | PASS | [build](contracts/mac/build.log) |
| macOS release `WorkbenchChecks` | PASS | [checks](contracts/mac/workbench-checks.log) |
| Linux portable | 10/10 PASS，包含 localization、radius、preview-sources | [results](contracts/linux-portable/results.json) |
| 生产 WindowGroup 冷启动 | 5/5 PASS，隔离偏好域，无远端验收 | [result](contracts/mac/app-launch/result.json) |
| 既有 workbench/sidebar/composer preview 构建 | 全部 exit 0 | [manifest](after/manifest.json)、[workbench](after/logs/build-workbench.log)、[sidebar](after/logs/build-sidebar.log)、[composer](after/logs/build-composer.log) |
| 正常 native-design 外观切换与布局 | PASS | [log](contracts/mac/native-design.log)、[geometry](contracts/mac/native-design/native-layout.json) |
| Sources 红线 | 除 `Sources/AgentWorkbench` 外为零 diff；WorkbenchCore 为零 diff | [sources](contracts/sources-redline.diff)、[core](contracts/mac/workbench-core-redline.diff) |
| PerfRunner 作业 | 同一代码头；porcelain 前后均 0；capture/gates 均 exit 0 | [capture](contracts/style-r1-capture-v1.log)、[gates](contracts/style-r1-gates-v1.log) |
| 本轮发布副本检查 | 0 findings；图片为既有虚构 fixture | [audit](contracts/public-source.log) |

Mac GUI 工作全部沿用已完成的 PerfRunner 作业，没有重新派发或直接运行 GUI 命令。
Linux portable 的 `dirty=true` 仅来自本轮未提交证据与保留的旧 round-0 未跟踪产物，
不是产品源代码改动；其测试代码头仍是 `b96cfdfa`。

### 2. 视觉层

[逐场景 before/after 比较](visual-comparison.json)：18 组机位、语言、字号和外观元数据
均可比；after 的 18 组 repeat-1/repeat-2 PNG 全部 byte-identical。

| 场景 | Before | After | 实际差异 |
|---|---|---|---|
| 主窗口 light，14pt | [before](before/main-light/repeat-1/capture.png) | [after](after/main-light/repeat-1/capture.png) | 零像素差异 |
| 主窗口 dark，14pt | [before](before/main-dark/repeat-1/capture.png) | [after](after/main-dark/repeat-1/capture.png) | 零像素差异 |
| 主窗口中文 fixture，18pt | [before](before/main-large-type/repeat-1/capture.png) | [after](after/main-large-type/repeat-1/capture.png) | `Re…` 恢复为完整 `Recap`；操作行按固有宽度排布 |
| 英文主窗口，14pt | [baseline](../round-0/baseline/main-english/repeat-1/capture.png) | [after](after/main-english/repeat-1/capture.png) | 零像素差异 |
| 其余主窗口与三个既有 preview | [round-0 baseline](../round-0/baseline/manifest.json) | [after matrix](after/manifest.json) | 其余全部零像素差异 |

只有 `main-large-type` 改变了 1325 个可见像素，PNG 坐标范围为
`[347, 457, 496, 477)`。所有变化均位于已允许的回复操作行；整组依固有宽度调整位置，
copy/quote/regenerate 保持相邻关系，没有重叠或换行。另 17 组可见像素完全一致。
比较沿用 round-0 的白底 alpha 合成口径，不把透明区域的不可见 RGB 当成产品变化。

[3× 放大对照](recap-before-after.png) 是原图 `[310, 426, 590, 503)` 的标注裁剪；
原始截图未缩放、覆盖或修改。

### 3. 回归层

- 外观跟随系统与 Settings 覆盖逻辑未修改；正常 native-design 明暗与布局检查通过。
- 验收与 preview 默认 fixture 仍钉 light；dark 只是既有截图参数，不改变产品默认值。
- 中文 14pt/18pt、英文 14pt 代表图已比较；18pt fixture 中的英文 `Recap` 已完整显示。
- 未覆盖英文 18pt 全主窗口、18pt dark、2× backing scale 或其他 S01 窗宽；不把代表图扩大为完整组合矩阵验收。
- 本轮未改动的 inspector 英文长标题、preview 英文筛选器等已知截断仍在 S02/S03 队列，
  不将既有问题伪装成本轮全部解决，也不顺手扩大修复范围。

## 衔接故障与伪影

原代理会话在 14:35:58 关闭，未归档 Mac 作业结果。作业自身继续执行：
capture 在 14:36:21 完成、gates 在 14:39:28 完成，均 exit 0。
2026-11-18 恢复时直接收回这些产物，未重做 round 0，也未重复提交 S01 产品修改。

首次数据信息传输在创建 `contracts/mac` 时因父目录不存在返回 rsync exit 11；
after 截图已经成功收回。创建证据目录后仅重取缺失的 contracts，未替换成新截图。
发布副本的 46 份文本日志/元数据进行了本机路径脱敏，原始产物保留在分支外的恢复证据中；
PNG 均保持原字节。衔接补丁与代理运行验收单独归档，不计作样式产品改动。
归档时 `git diff --check` 仅报告三处编译器日志中的原始行尾空格；保留取证日志，
排除这三份未改写的原始日志后，提交差异检查通过，不为格式化而重写构建证据。
预期清单的首次写入时间未独立认证；本次评审证明实际差异与已归档清单一致，
不将这一内部一致性当作清单必然先于原截图写入的取证证明。

## 独立评审

`acpRegistry_kimi_code` / `aone/gpt-6.1-sol`、`thinking=max` 已完成独立评审：
[review-1.json](review-1.json)，结论 PASS，无新增 P1/P2 finding，无需产品复核轮。
评审仅检查契约、红线、截图与差异清单一致性、已裁决方向，不裁美。
独立解码核对了 72 张 PNG、机位/fixture 元数据、18 组双跑字节一致性与差异 bbox；
未重新运行已完成的 GUI、构建或真实连接，也未认证未脱敏原件或远端二进制身份。
评审后的收尾只更新报告、清单边界与索引，不改产品、截图或原始作业证据。
本轮证据仍对应真实测试头 `b96cfdfa`；补齐证据的提交不是重新采集或测试的代码头。

本轮已计为完成，距上次用户汇报还剩 **18 轮**。下一轮取 S02，不重复改动 S01。
