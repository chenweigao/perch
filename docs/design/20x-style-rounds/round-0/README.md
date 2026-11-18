# Style loop round 0：截图基建与候选队列

日期：2026-11-18。分支：`style/loop-main`。基线：`origin/main` = `9ed2ac1c`。
最终视觉/产品证据代码头：`9c3fbb0adf6cc7d2e9f82eb5fe21008ae0530deb`。
本轮没有审美改动、没有 PR、没有合并请求。

## 假设与范围

假设：复用真实生产视图与既有 preview，在固定 fixture、窗口位置/尺寸和隔离偏好域下，
可以通过 PerfRunner + 原生 `screencapture` 得到双跑逐像素一致的 light/dark 基线，
并据此建立不重开已裁决方向的样式队列。

改动仅限验收/preview 与新增 `scripts/capture-style-loop.py`：
固定窗口、静态内容、语言/字号/appearance 变体、窗口元数据、双跑 PNG 比较与日志。
`Sources/AgentWorkbench`、`Sources/WorkbenchCore`、`Sources/` 其余目录均零 diff；
性能测量与 CI 门槛脚本零改动。正常产品启动、外观跟随系统和 fixture 默认 light 不变。

## 三层证据

### 1. 契约层

| 检查 | 结果 | 证据 |
|---|---|---|
| Linux `swift run WorkbenchChecks` | PASS | [日志](contracts/linux-workbench-checks.log) |
| Linux portable | **10/10 PASS**，含 localization、radius、preview-sources | [results](contracts/linux-portable-results.json) |
| macOS `scripts/build.sh` | PASS | [日志](contracts/macos-build.log) |
| macOS `swift run -c release WorkbenchChecks` | PASS | [日志](contracts/macos-workbench-checks.log) |
| 生产 WindowGroup 冷启动 | **5/5 PASS**，隔离偏好域 | [结果](contracts/macos-app-launch-result.json) |
| workbench/sidebar/composer preview 构建 | 全部 PASS | [workbench](contracts/macos-build-workbench.log)、[sidebar](contracts/macos-build-sidebar.log)、[composer](contracts/macos-build-composer.log) |
| 正常 native-design 外观切换与几何检查 | PASS | [日志](contracts/macos-native-design.log) |
| Sources 红线 | `git diff origin/main -- Sources` 为空 | [空 diff](contracts/sources-redline.diff) |
| PerfRunner 作业完整性 | checkout 最终代码头，porcelain 前后均 0 | [视觉作业](contracts/perfrunner-capture.log)、[产品 gates](contracts/perfrunner-gates.log) |
| 发布检查 | `check-public-source.py` **0 findings**；截图均为虚构 fixture，日志本机路径已脱敏 | 本报告与基线图 |

### 2. 视觉层

[最终 manifest](baseline/manifest.json)：**18/18 场景双跑一致，36 张 PNG 全部字节一致**，
因此可见像素也一致；尺寸固定，机位无漂移。PNG 比较器仅在字节不同的情况下解码，
合成白底比较可见像素，避免透明 RGB 伪差异。

| 目标 | 场景（每个均有 repeat-1/repeat-2） | 尺寸 | 索引 |
|---|---|---|---|
| 主窗口 | light、dark、english、large-type、find、find-dark、inspector-closed、dashboard、scroll（长对话底部锚定） | 1536×900 | [baseline/main-*](baseline/) |
| Workbench preview | light、dark、english、empty-light | 1120×820 | [workbench-light](baseline/workbench-light/repeat-1/capture.png)、[dark](baseline/workbench-dark/repeat-1/capture.png)、[empty](baseline/workbench-empty-light/repeat-1/capture.png) |
| Sidebar preview | light、dark、english | 1100×760 | [sidebar-light](baseline/sidebar-light/repeat-1/capture.png)、[dark](baseline/sidebar-dark/repeat-1/capture.png) |
| Composer preview | light、dark | 760×500 | [composer-light](baseline/composer-light/repeat-1/capture.png)、[dark](baseline/composer-dark/repeat-1/capture.png) |

独立评审指出旧矩阵的 no-op 变体后，已删除 sidebar/composer `empty-light`、三个 preview
`large-type` 与 composer `english`：这些图与默认 light 完全相同，不能证明空态、字号或语言覆盖。
最终只保留真实可区分的场景；语言与放大字号回归由主窗口及 Workbench/Sidebar 的有效变体承担，
不再把重复图计入覆盖率。

本轮没有 before/after 审美差异。预期差异清单只有截图基建与其 fixture 输出；
出现任何产品 Sources 差异都视为越界并回滚，最终 `Sources` diff 为空。

preview 顶部系统框外区域为 **alpha=0**，在查看器里可能显示为白色；它不是白色标题栏。
暗色评审只看不透明内容区，不用框外透明区推断产品对称性。滚动场景覆盖底部跟随，
不声称覆盖回顶按钮；一次 wheel 回顶探针未改变锚点，已记入伪影链且未作为成功证据。

### 3. 回归层

- 外观跟随系统：产品 `WorkbenchApp` 未改；正常 native-design 的 light/dark 切换断言通过。
- fixtures：无环境变量时仍为中文、light、默认字号；dark/english/large-type 只能由截图环境变量显式触发。
- 中文、英文、默认字号和 18pt 均有同机位代表图。
- **基线已有截断，不能记为回归全绿**：18pt `Recap`（S01）、英文 inspector 标题（S02）、
  英文 preview 筛选器（S03）。除此之外，已审阅代表图未见文字重叠。
- 截图不读取真实会话、真实 SSH 配置或用户草稿；没有远端 Agent 连接。

## 队列初始化

[INDEX](../../20x-style-loop/INDEX.md) 记录 8 条候选：3 条截断契约问题优先，
其后为暗色对比度、查找栏/sidebar/inspector 排版。所有条目标记「不触碰已裁决方向」，
没有「提案-待批」。下一轮取 **S01**；距用户 20 轮汇报点还剩 **19 轮**。

## 伪影与独立评审

基建失败、TCC 权限链、动画漂移、编译修正、比较器优化和非最终 gates 全部见
[attempts/README.md](attempts/README.md) 及同目录原始日志。最终证据只取上述 v20 视觉作业与
v9 产品 gates。

## 独立评审与处置

首轮 `aone/gpt-6.1-sol`（thinking=max） verdict：**BLOCKING**，[原始 findings](review-1.json)。

1. **P1 / inspector-closed 是重复图**：已将场景改为 `embeddedVisible=false`，并在 capture-ready
   前断言关闭状态；双跑与 manifest 重新生成。
2. **P2 / sidebar、composer empty-light 是重复图**：删除无真实空态的变体和对应索引，
   只保留 Workbench 的真实首次使用空态，不把默认 populated 图算作空态覆盖。
3. **P2 / preview large-type 与 composer english 是 no-op**：删除这些变体，明确披露；
   repeat 稳定性不再被当作有效场景覆盖。

复核由同一模型的新 `delegate_task`（wait 模式，thinking=max）完成，verdict：**PASS**，
findings 为空，[复核结果](review-2.json)。评审确认 18 组图的 repeat 均一致、组间可见像素不同，
inspector-closed 与开放基线确实不同，最终 gates 与红线成立。
