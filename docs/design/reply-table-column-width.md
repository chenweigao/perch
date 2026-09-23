# 回复表格列宽不协调：问题分析与方案对比

状态：B 方案已实现并通过仓内检查；**目视与性能验收未做**（本会话无法查看图像，也未做滚动/流式性能测量）。
基线：`main` @ `11dbe6f`（worktree 分支 `codex/reply-table-width`）。实现记录见 §9。

## 1. 问题

Agent 回复里的 Markdown 表格，列宽与内容长度无关：窄内容列（`#`、「成本」）拿到和长文本列（「为什么」）
一样的宽度，于是窄列大片留白、长列反复折行，整张表看起来不协调。列数一多还会触发横向滚动。

用户观察来源：Kimi Code 回复中的 4 列决策表（`#` / 做什么 / 为什么 / 成本），在默认阅读列宽下渲染。

## 2. 现状实现（读代码确认）

渲染入口与实现都在 `Sources/AgentWorkbench/ReplyMarkdownView.swift`：

| 位置 | 事实 |
|---|---|
| `:86-87` | `.table(headers, rows, alignments)` → `ReplyTable(headers:rows:alignments:)` |
| `:312` | `minimumCellWidth = 100`（每列最小 100 pt） |
| `:313` | `cellPadding = 12`（左右各 12 pt） |
| `:316-319` | 外层 `ScrollView(.horizontal)` + `containerRelativeFrame`：宽 = `max(视口宽, 列数 × (100 + 24))` |
| `:324` | `Grid(horizontalSpacing: 0, verticalSpacing: 0)` |
| `:327` | 行间分隔线：`Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)` |
| `:333-339` | 每格 `ReplyText(size: 13, weight: header ? .medium : .regular)` + `.frame(minWidth: 100, maxWidth: .infinity)` + `.padding(.horizontal, 12).padding(.vertical, 10)` |
| `:135-155` | `ReplyText` 走 `NSAttributedString` + TextKit，`lineBreakMode = .byWordWrapping`；`docs/REPLY-READING.md:230` 说明可选中文本由 AppKit `NSTextView` 承载 |
| `:93-95` | 同文件已有 `ReplyListLayout: Layout`，注释写明「Measure wrapped rows at the actual column width without a geometry/state loop」——本仓已有的测量范式 |

## 3. 根因

**所有列都是 flexible（`minWidth: 100, maxWidth: .infinity`），SwiftUI `Grid` 把可用宽度在 flexible 列之间等分，
不按各列内容的理想宽度加权**；同时 100 pt 的地板让窄内容列无法收窄。

按 13 pt 字号、760 pt 阅读列宽推算（**计算值，非实测**）：

- 4 列表：容器宽 `max(760, 4 × 124) = 760`，每列约 190 pt，扣 padding 后文本宽约 166 pt。
  `#` 列内容 1 个字符（约 8 pt）→ 约 158 pt 空白；「为什么」列 40 个中文字（约 520 pt）→ 折 4 行。
- 7 列表：最小宽 `7 × 124 = 868 pt > 760` → 横向滚动（`docs/REPLY-READING.md:28-30` 的契约允许），
  但每列仍等分约 124 pt，长单元格折行更严重。

即：两个失败模式同源——**列宽分配与内容无关**。

## 4. 候选方案

| 方案 | 改动面 | 与现有契约 | 主要风险 | 成本 |
|---|---|---|---|---|
| A 内容侧规避（agent 少列、短单元格、编号并进首列） | 0 行代码 | 不冲突 | 不解决根因；只对遵循约定的 harness 有效，其他来源的表格照旧 | 0 |
| B 加权列宽：新增 `ReplyTableLayout: Layout`，按各列最长 cell 的理想宽加权分配，保留（或下调）100 pt 地板，总宽仍先 fit 视口、超宽才滚 | 仅 `ReplyTable` 内部；不动 Markdown 解析、虚拟化行、可选中文本 | 符合 `docs/design/reply-typography.md:18-20`「只改 presentation metrics，不动 cached TextKit measurement / virtualized rows」；沿用 `ReplyListLayout` 既有范式 | 测量若走 GeometryReader/state 会重蹈 `docs/REPLY-READING.md:36` 的 intrinsic-size loop；需要给极长 cell 设上限 | 半天 |
| C 换 macOS 原生 `Table` | 换容器控件（NSTableView 背书） | 与多条契约冲突，见 §5 | 长单元格截断、行高需手算、独立滚动容器嵌进 lazy transcript、选中/复制行为变化 | 1–2 天，且更脆 |

## 5. C 方案与现有契约的冲突（这是本文的主要结论）

| 冲突 | 证据 |
|---|---|
| 单元格是多行段落且要可选中；`Table` 行高固定，长文本会截断而不是折行 | `ReplyMarkdownView.swift:135-155`（TextKit + `byWordWrapping`）、`docs/REPLY-READING.md:230`（NSTextView 承载可选中文本）、`docs/REPLY-READING.md:57-60`（预览用例明确含「三列长单元格」） |
| 表格宽度契约是「按视口定宽 + 100 pt 最小列宽 + 只有超宽才横向滚」 | `docs/REPLY-READING.md:28-30` |
| 时间线用 stable lazy rows，是修完 intrinsic-size loop 才稳定的；`Table` 是独立滚动容器，嵌进去要手算高度并会与外层抢滚动 | `docs/REPLY-READING.md:36` |
| 表格外观基准是「无卡片的文档式表格 + 水平分隔线」，参考 Codex 桌面默认样式；`Table` 自带表头 chrome、行选中高亮、可拖列 | `docs/design/reply-typography.md:1-20` |
| 现有验收样本要重做 | `Tests/ReadingPreview/App.swift`、`docs/REPLY-READING.md:57-60`（420 / 700 / 760 pt 宽度对比、七列表格独立滚动）、`:49`（`WorkbenchChecks` 覆盖转义竖线等表格用例） |

若仍要走 C，建议先做一个 ReadingPreview 里的 spike，只回答三件事：
段落级单元格能否不截断、行高怎么确定、在 lazy transcript 里的高度与滚动行为是否可接受。
spike 不过就退回 B。

## 6. 建议

**做 B**：保留 `Grid` + `NSTextView` 单元格与既有宽度契约，只把「等分」换成「按内容加权」。
用户要的协调感来自列宽与内容匹配，B 直接命中，且不动解析、虚拟化、可选中与性能路径。
A 可以作为并行的临时缓解（我这边的回复约定已经在压列数），但不能替代 B。

验收方式（都在仓内，无需新工具）：

1. `Tests/ReadingPreview/App.swift` 目视：420 / 700 / 760 pt 三档列宽下，
   三列长单元格表、七列宽表、含 `#` 窄列的 4 列表，窄列不再留白、长列折行数下降、七列表仍独立横向滚动。
2. `swift run WorkbenchChecks` 保持通过（表格结构、转义竖线、内联样式用例）。
3. `scripts/build.sh` 构建通过；性能证据按 `AGENTS.md` 要求与 UI 证据分开记录。

## 7. 证据边界

- **读代码确认**：§2 全部行号事实、§5 引用的文档条款。
- **推断未实测**：`Grid` 对全 flexible 列严格等分的语义；`Table` 行高固定导致截断的行为；§3 的宽度与折行数值（按 13 pt / 760 pt 推算）。
- **未做**：任何构建、Running ReadingPreview、`WorkbenchChecks`、性能测量。本文不含实测数据。

## 8. 给评审人的问题

1. `Grid` 在所有列都 flexible 时是否严格等分剩余宽度？（§3 的根因判断依赖这一点，尚未实测）
2. 加权口径取哪个：各列最长 cell 的理想宽、字符数启发式、还是按 header 宽？极长 cell（整段代码/长 URL）如何设上限？
3. 100 pt 最小列宽是否下调（例如窄列 44 pt）？下调后中文长词折行是否可接受？
4. 在 `Layout` 里测量是否会与 virtualized rows 的 cached TextKit measurement 冲突（`reply-typography.md:18-20` 要求不动这部分）？
5. 若走 C：可拖列宽是否需要持久化成用户偏好？与 760 pt 阅读列宽如何协同？

## 9. 实现记录（B 方案）

全部改动在 worktree 分支 `codex/reply-table-width`，未提交、未推送。

| 文件 | 改动 |
|---|---|
| `Sources/WorkbenchCore/ReplyTableGeometry.swift`（新增） | 纯算术列宽：估算单行内容宽（宽字符 ≈1 em、行内代码 ≈0.62 em、其他 ≈0.55 em）→ 每列地板（窄列 44 pt、常规 124 pt）→ 富余按未满足需求注水、单列内容上限 420 pt → 仍有富余则按内容权重填满视口。取整为整数点、排序确定、不超过 `available` |
| `Sources/AgentWorkbench/ReplyMarkdownView.swift` | `ReplyTable` 从 `Grid` 等分改为 `ReplyTableLayout: Layout`，row-major 放置单元格；列宽来自上面的纯函数，单元格只为行高测量。共享参数放在 `ReplyStyle.tableGeometry` |
| `Tests/WorkbenchCoreTests/ReplyTableGeometryTests.swift`（新增）、`ProtocolTests.swift` | 可复算检查：窄列不吃常规地板、长列拿走富余、需求竞争时 420 pt 上限生效、低于地板整体溢出（横向滚动契约不变）、同输入同输出、取整不超过 `available`、残缺表与空表仍合法 |
| `docs/REPLY-READING.md` | 表格契约句改为按内容分宽，并写明单元格只为行高测量、宽度探针不进 TextKit |
| `Tests/Fixtures/reply-reading.md` | 新增「窄列 + 长列」决策表样本（右对齐窄列、两字窄列、40 字长列），Reading Preview 直接覆盖本次问题 |

### 为什么预期不引入卡顿（设计层面，未实测）

- 没有 GeometryReader、`@State`、PreferenceKey、`onGeometryChange`：列宽是 `proposal.width` 的纯函数，不存在布局反馈回路。
- 列宽不探针 TextKit：旧 `Grid` 需要各单元格的理想宽度来定列宽，新实现只按最终列宽测行高，**文本测量次数预期不增反减**（推断，未实测）。
- 内容宽度估算只扫字符、不构造 `NSAttributedString`；在 `ReplyTable.init` 算一次并随视图值存储，布局回调里不重复扫描。
- 行高测量沿用 `ReplyTextView.measurements` 的按宽度缓存，与 `ReplyListLayout` 同一范式（`measure` 在 `sizeThatFits` 与 `placeSubviews` 各走一次，第二次命中缓存）。

### 验收状态

已通过：

- `swift run WorkbenchChecks`（exit 0），含新检查 `PASS: reply table column widths, narrow-column floors, capped surplus, deterministic rounding`。
- `swift build --target AgentWorkbench`（debug）与 `scripts/build.sh`（release，产出并签名 `build/Perch.app`）。
- 两个目视样本 app 已构建：`build/Reply Reading Preview.app`、`build/Reply Typography Preview.app`。

未做（按 `AGENTS.md`，UI 与性能证据分开记录）：

- **目视验收**：本会话无法查看图像，窄列是否收窄、长列折行是否减少、七列表是否仍独立横向滚动，需人工打开上面两个 app 确认（Reading Preview 有 420 / 700 / 760 pt 宽度档与窄列开关）。
- **性能测量**：未做滚动、流式与长历史的帧时间测量；`docs/performance/` 的既有口径未被本次改动触碰，但也没有新证据。

### 构建环境备注

已修（本分支内，与表格改动同一 worktree）：

- `scripts/build-reading-preview.sh`、`scripts/build-reply-typography-preview.sh` 的 `bin_dir` 改用
  `swift build --build-system native -c release --show-bin-path`，与 `scripts/build.sh:15` 和
  `scripts/build-navigation-preview.sh:10`、`scripts/build-native-acceptance.sh:14` 已有的写法一致。
  原来的 `swift build -c release --show-bin-path` 在本机工具链上返回 `.build/out/Products/Release`（不存在），
  release 产物实际在 `.build/arm64-apple-macosx/release`。两个脚本删掉旧 app 后重跑通过，产出并签名新的
  `ReplyReadingPreview` / `ReplyTypographyPreview`。
- `scripts/build-reply-typography-preview.sh` 补上可执行位（git 模式 100644 → 100755），此前只能 `bash` 调用。

未修（同一 stale 写法，但与本任务无关，未在本分支动）：

- `build-activity-bar-preview.sh:5`、`build-composer-toolbar-preview.sh:5`、`build-localization-preview.sh:4`、
  `build-performance-preview.sh:28`、`build-tool-visibility-preview.sh:5`、`build-workflow-preview.sh:5`
  仍用不带 `--build-system native` 的 `--show-bin-path`。
- `build-public-demo.sh:6`、`build-task-group-preview.sh:6`、`build-workbench-preview.sh:6` 走
  `--package-path "$build_root"`，本次未验证。
- `scripts/build-sidebar-preview.sh` 在 git 里同样是 644。
- 两个预览脚本依赖 `rg`；本机原先没有，已在 `~/.local/bin/rg` 安装 ripgrep 15.2.0（机器级改动，不在仓库内）。
