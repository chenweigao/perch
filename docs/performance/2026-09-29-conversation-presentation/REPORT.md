# 会话展示模型与有界复用

本轮把工具状态、对话投影、导航摘要、活动摘要和逐行工具映射提取为独立展示模型，
让工作台保留最近使用的八个符合预算的会话。结果支持减少重复计算；整体切换耗时
的三轮波动区间仍重叠，不能据此承诺用户可感知的提速。保留这项边界，下一步继续
定位 SwiftUI 更新和 AppKit 布局，而不是立即扩展缓存或引入框架。

## 实现与正确性

- 完整输入决定是否复用，包括同 ID 消息的正文/工具结果、实时工具、运行状态、
  在线状态、历史 epoch、语言和摘要设置。外部摘要在展示时叠加，不冻结在缓存中。
- 切换运行时清除旧实时工具证据；切换语言只重建本地化投影，保留未落盘工具的交接。
- 每个共享条目最多 1,000 条源消息、1 MiB 估算载荷成本，包含嵌套 JSON 和记住的
  实时工具。估算不是进程内存上限；Swift 容器、派生数据与视图另有开销。
- 超预算会话正常显示，在当前视图内复用，离开后不进入共享缓存。共享缓存按
  host/provider/session 区分，删除会话、移除主机及退出时清理。
- 共享缓存只保留计算模型，不保留 AppKit 行、网络连接或任务。原有阅读锚点、
  摘要任务生命周期和连接生命周期继续使用现有边界。

## 固定应用交替对照

Apple M4、16 GiB、macOS 27.0（26A428），Swift 6.4、release -O，1280×820。
旧版源码摘要已逐文件验证与 `2809890` 相同；旧二进制构建清单中的提交字段仍为
`374ada5`，因为它在上一轮测量提交前构建。新版为 `2809890` 加本轮生产代码及
验收计数修改。精确源码、二进制摘要和工具链记录在 measurements.json。

每轮旧版→新版，串行重复三轮；测量期间没有并行运行本任务的编译或 profiler。
其他桌面进程未受控制。每次使用 500 条目录、200 轮正文和八个驻留源快照，80 次
切换同时刷新目录状态、排序和收藏区，终点检查对应正文与草稿已挂载。

| 指标 | 旧版 | 新版 |
| --- | ---: | ---: |
| 三轮切换中位数的中位数 | 78.72ms | 77.63ms |
| 三轮中位数范围 | 78.41–79.18ms | 73.07–80.65ms |
| 三轮 p95 范围 | 87.96–93.23ms | 84.51–91.97ms |
| 滚动后静置 RSS 范围 | 218.39–219.31 MiB | 217.64–222.20 MiB |

新版每轮均为 8 次展示准备、72 次跨视图缓存恢复，估算共享载荷为 1,860,288 字节。
本场景工作集正好等于缓存容量，结果不代表任意数量会话的命中率。超过容量、不同
主机同 ID、缓存淘汰、条目增长超预算和释放由核心回归单独检查。

## 独立 CPU 采样

另行采集新旧各一次 Time Profiler，通过 `CatalogSwitching` signpost 截取切换区间，
排除启动、空闲和后续滚动。旧版区间为 2.978–9.348 秒，新版为 2.949–8.942 秒。

| 主线程采样指标 | 旧版 | 新版 |
| --- | ---: | ---: |
| 区间主线程采样权重 | 6243ms | 5864ms |
| `ConversationProjection.update` inclusive | 360ms | 33ms |
| `ConversationTurnSummary.make` inclusive | 321ms | 27ms |
| `AG::Graph::UpdateStack::update` inclusive | 3465ms | 3099ms |
| `NSView._layoutSubtreeWithOldSize` inclusive | 2515ms | 2374ms |
| `ConversationDocumentView.configure` inclusive | 534ms | 547ms |
| `ConversationDocumentView.refreshVisibleRows` inclusive | 519ms | 518ms |
| `ConversationEntryController.measure` inclusive | 470ms | 467ms |

投影和摘要的重复计算明显减少，行配置与测量成本基本保留。以上 inclusive 权重彼此
重叠，不能相加，也不是独占耗时或 FPS。单次采样用于定位，不替代多轮响应耗时结论。

## 输入、流式更新与内存

原生和 Kimi 分别在新旧版本各运行三轮真实挂载控件输入，每组 72 次中文组字循环。
流式更新、marked text、提交草稿、Return 归属和阅读位置全部检查通过；普通输入和
中文提交期间，阅读区 body 重算均为 0，最大锚点偏移为 0 points。

| 控件方法入口到布局：三轮中位数的中位数 | 旧版 | 新版 |
| --- | ---: | ---: |
| 原生普通输入 | 3.42ms | 3.47ms |
| 原生中文提交 | 3.15ms | 3.23ms |
| Kimi 普通输入 | 4.86ms | 4.98ms |
| Kimi 中文提交 | 3.60ms | 3.69ms |

没有从这些数字得出输入变快的结论；新版的小幅上升也完整保留。测量包含异步就绪
等待，流式组字路径额外等待 10ms；不覆盖硬件事件、真实输入法候选框或显示延迟。
新增版本的 80ms 人工延迟对照成功检测，控制样本不混入常规统计。

新旧各一次 120 秒流式对照均完成 296 次更新、18 次切换，保留视图检查通过。
30/60/90 秒 RSS：旧版 187.81/189.88/191.91 MiB，新版 187.23/189.20/192.09 MiB；
后续滚动并静置后为 199.95/199.73 MiB。候选运行中 mounted 为 3–4、retained 为
4–6，没有触及保留上限。这是短期固定场景数据，不是长期无泄漏证明。

两分钟进程 CPU 为旧版 12.45s、新版 11.92s，包含 fixture JSON 序列化；单次数据
不作为生产流式性能提升结论。刷新到布局中位数为 28.07/27.12ms。

## 验证和复现

核心检查覆盖投影等价、同 ID 编辑、分页、语言/epoch、工具交接、外部摘要叠加、
LRU、不同主机、超预算及释放。宿主生命周期检查覆盖移除主机与退出清理。
原生离线验收的 12 个模式及输入人工延迟对照全部通过。
生产构建、签名/版本、WorkbenchChecks、ConnectionChecks、宿主生命周期和 18 项
Python 测量/源码导出检查通过。六种独立预览编译通过，导航预览的 reading、
interactions、roundtrip 验收通过。预览脚本同步补齐展示环境依赖，保持历史源码
导出兼容，并修复旧脚本的 SwiftPM 构建目录和模型选择器依赖遗漏。


- `scripts/build-native-acceptance.sh`，保存新旧 `.app`，用 `--app` 指向固定应用。
- `scripts/run-native-acceptance.py --mode switching --app <应用> --output <新目录>`。
- `input` / `kimi-input` 各版本各三轮，用 `summarize-input-runs.py` 分别汇总。
- `--mode joint --seconds 120`；独立采样使用 `--mode switching --capture cpu`。
- 从 os-signpost 提取完整区间，再给 `summarize-time-profile.py` 传入 `--after` / `--before`。

[measurements.json](measurements.json) 保留逐轮统计、构建身份、CPU 采样摘要和验收
回执；[input-samples.json](input-samples.json) 保留逐次输入样本。完整 traces、原始
回执及固定应用位于本工作树 `.local/presentation/`。早期 pilot 不计入对照统计。
本轮没有真实 SSH、真实模型、真实输入法候选框或 FPS 验收。
