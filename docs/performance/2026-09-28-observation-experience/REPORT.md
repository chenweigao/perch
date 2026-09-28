# Observation 迁移后的体验基线

当前优先调查会话切换时的视图更新与布局。输入区已经保持局部更新，当前数据没有
显示需要为输入路径更换架构框架。本轮新增测量与回归检查，没有修改生产功能行为，
也没有把新基线解释为相对旧版本的延迟改善。

## 条件和结果

Apple M4、16 GiB、macOS 27.0（26A428）；release -O，1280×820 窗口。
每种输入场景串行运行三次，每次 24 个普通输入/中文组字/流式更新/提交循环。
测量期间未并行运行本任务的构建或 profiler；其他桌面进程不受控制。
原生和 Kimi 各使用 200 轮固定离线历史，数据内容不同，不用两者的数字评选提供商。

| 场景 | 三轮中位数的中位数 | 三轮中位数范围 | 三轮 p95 范围 |
| --- | ---: | ---: | ---: |
| 原生：普通文本到布局 | 3.66ms | 2.94–3.69ms | 3.83–4.46ms |
| 原生：中文提交到布局 | 3.55ms | 3.09–3.59ms | 3.58–4.08ms |
| Kimi：普通文本到布局 | 4.10ms | 3.33–4.76ms | 3.91–5.51ms |
| Kimi：中文提交到布局 | 3.54ms | 3.07–3.58ms | 4.83–6.48ms |
| 原生：目录刷新期间切换到正文和草稿 | 78.93ms | 78.70–80.07ms | 89.34–91.46ms |

输入计时从真实挂载的 NSTextView 的 `insertText` / `setMarkedText` 方法入口开始，
经过生产 delegate、draft binding、布局与 display flush。中文提交的同步调用中位数
约 0.56–0.59ms；表中的布局数字还包含至少 1ms 异步就绪等待。流式组字检查有固定
10ms settle，单列保存，不能当作纯刷新耗时。硬件键盘事件、真实输入法候选框、
窗口合成器、显示器、网络均未覆盖，结果不是用户感知延迟或 FPS。

两类会话各 72 次中文组字循环全部通过：流式更新不覆盖 marked text，未提交内容
不进入草稿，Return 仍归输入法，提交后草稿与编辑控件一致。每类 72 次普通输入
和 72 次中文提交期间，阅读区 body 重算均为 0；阅读锚点最大偏移为 0 points。
80ms 人工延迟正向对照测得 84.01ms，检测通过；该样本不混入常规结果。

切换场景每轮 80 次，同时改变 500 条目录记录的状态、顺序和收藏区存在性；
这是目录刷新压力场景，不代表普通静态目录切换。计时终点验证正文及对应草稿已挂载。

## 持续更新和内存边界

单次持续更新运行 120.35 秒，完成 294 次更新、18 次会话切换，草稿、阅读锚点和
视图保留数量检查通过。30/60/90 秒时 RSS 分别为 188.36/185.92/187.97 MiB；
随后完成滚动阶段并静置后为 196.30 MiB。采样视图 retained 为 4–6，mounted 为 3–4，
没有触及现有保留上限。这只是在本场景中未见保留视图持续累积，不是长期无泄漏证明。
进程 CPU 共 11.96 秒，包含 fixture JSON 序列化，不作为生产刷新成本。

## 切换区间的 Instruments 线索

另行采集 Time Profiler，通过 `CatalogSwitching` signpost 限定 3.087–9.469 秒区间，
排除启动、后续空闲和滚动。该区间主线程采样权重为 6253ms。

| 采样栈包含的符号 | inclusive 采样权重 |
| --- | ---: |
| `AG::Graph::UpdateStack::update()` | 3473ms |
| `NSView` 子树布局 | 约 2598ms |
| `ConversationDocumentView.configure` | 555ms |
| `ConversationDocumentView.refreshVisibleRows` | 540ms |
| `ConversationEntryController.measure` | 479ms |
| `ConversationProjection.update` | 359ms |
| `ConversationTurnSummary.make` | 318ms |

这些权重彼此重叠，不能相加，也不是各函数的独占耗时。它们把下一轮实验范围指向
切换时的 SwiftUI 更新、正文重建和测量；投影/摘要计算也值得跟踪，但不能仅凭这份
采样就认定移到后台或增加缓存会改善整体响应。

下一步先做正文视图/投影复用的有界对照实验，保留快速切换、同 ID 内容更新、阅读
锚点和内存上限检查。TCA 留给具有组合、取消、重试需求的独立功能试验；当前证据
没有把这里的布局成本归因于缺少 TCA。真实输入法、真实 SSH 和长时间使用仍需单独验收。

## 复现与证据

- `scripts/build-native-acceptance.sh`
- `scripts/run-native-acceptance.py --mode input --output <新目录>`；Kimi 使用 `kimi-input`。
- 两种场景各重复三次，再用 `scripts/summarize-input-runs.py <六个目录>` 汇总。
  汇总器拒绝混用源码、二进制、工具链、窗口尺寸、profiler 或人工延迟样本。
- 输入对照：`--mode input --input-positive-control`。
- 切换：`--mode switching`；持续更新：`--mode joint --seconds 120`。
- 独立 CPU 采样：`--mode switching --capture cpu`。通过 signpost 定位区间，再用
  `scripts/summarize-time-profile.py <time-profile.xml> --after <起点秒> --before <终点秒>`。

基线基于 `374ada5` 加本提交的验收 instrumentation；精确源码摘要、二进制摘要、
工具链、环境、逐轮统计与采样摘要见 [measurements.json](measurements.json)，
逐次输入样本见 [input-samples.json](input-samples.json)。完整 trace 和运行 receipts
保留在本工作树 `.local/experience-baseline/`，不提交大型 trace。

新增两种输入模式及人工延迟对照已接入 macOS functional CI。CI 检查语义和检测能力，
不把本机毫秒数作为共享 runner 的性能阈值。本轮本地通过 17 项 Python 测量/监管测试、
现有 AppKit composer 检查、上述重复界面场景和独立采样。
