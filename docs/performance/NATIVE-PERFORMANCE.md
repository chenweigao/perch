# Perch 原生交互性能验收

流畅度验收同时检查响应、显示卡顿、资源边界和阅读正确性。构建成功与功能检查通过不代表流畅；指标必须标明计时起止、场景、样本数、工具和限制。

## 固定执行入口

```sh
scripts/build-native-acceptance.sh
python3 scripts/run-native-acceptance.py --output .local/native-run-1
python3 scripts/run-native-acceptance.py --capture cpu --output .local/native-cpu
python3 scripts/run-native-acceptance.py --capture frames --output .local/native-frames
python3 scripts/run-native-acceptance.py --capture frames --positive-control --output .local/native-frame-calibration
```

验收 app 为 `build/Perch Acceptance.app`，bundle ID `dev.perch.nativeacceptance`。无启动参数时可手动体验。它编译完整的正式 `WorkbenchView`、`WorkbenchSidebar`、`SessionDirectoryView`、`NativeAgentView` 和正文组件；仅入口、固定数据和观测探针受 `PERCH_ACCEPTANCE` 编译标志控制。普通 `scripts/build.sh` 不包含该入口或探针。

固定条件：1280×820pt、Release、500 个目录会话、8 个本地 JSON 响应、每个响应 200 轮文字／表格／代码消息。使用现有 NativeAgentConnection transport 注入，保留实际选择、取消旧选择、JSON 解码和 SwiftUI 发布路径。不会读取保存的主机／工作区／草稿，不启动后台连接，不保存工作区；摘要关闭。只有前 8 个会话有正文，其他项用于目录规模与筛选验收；访问未预置数据明确报错。

这不是远端连接、终端或流式数据整合验收，也不是旧 Navigation Preview 的缓存命中切换基准。两者不可直接比较加速比。

## 观测契约

| 指标 | 采集边界 | 不能声称 |
| --- | --- | --- |
| 查询到布局提交 | 测试 publisher 写入正式面板的局部 query 状态，到渲染标记、layout/display 和 CA flush | 硬件键盘到屏幕的延迟；IME 验收 |
| 会话切换 | model.open 到本地传输、实际 JSON 解码和内容布局完成 | 远端延迟；纯缓存命中耗时 |
| 滚动步耗时 | 程序化位移到 layout/display/CA flush | 屏幕 FPS 或实际掉帧数 |
| Instruments 帧数据 | 目标进程的 update/hitch 事件；按 display、swap 和 surface 关联帧生命周期 | 把 WindowServer 全局事件全部计入 Perch |
| 内存／保留宿主 | 同一工作负载前后 RSS、静置结果与 mounted/retained/retired 数量 | 单次 RSS 上升就是泄漏；短测无泄漏即长期通过 |

阶段标记使用 `OSSignposter`：SessionSwitch、DirectoryQuery、HistoryScroll。一次标记只对应一次区间；异常期间未闭合的区间不能当有效样本。自动搜索探针不重复执行 sessions 筛选；预期选择的计算放在计时之外。自动输入不覆盖事件投递，因此仍需真实键盘、触控板和输入法验收。

Apple 文档：[响应性预算](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)、[SwiftUI 性能分析](https://developer.apple.com/videos/play/wwdc2025/306/)、[Signpost](https://developer.apple.com/documentation/os/ossignposter)。连续交互主线程工作约 5ms 是工程预算，不是把现有滚动回放数值换算成显示帧率的公式。

## 对照与门槛

1. 第一次在固定机器上连续重放同一版本至少 3 次，先记录噪声；对照改动时交替运行基线／候选，固定内容、窗口、构建配置、显示器／刷新率、供电和机器负载条件。
2. 无 profiler 的结果用于交互耗时比较；带 profiler 的结果用于归因，分别保存。采样累计 inclusive 时间不可相加或当作可获得加速比。
3. 每次提交跑受影响场景及消息覆盖、阅读锚点、折叠状态回归。发布前补真实输入法、触控板、文本选择、图片、快速反向、回到最新、流式期间输入和会话切换。
4. 搜索与点击可见反馈的目标为 p95 ≤50ms／p99 ≤100ms；缓存命中正文就绪目标 p95 ≤100ms。这些是产品目标；当前探针没有测硬件输入到呈现，不能冒充这两项门槛已经通过。采样数量不足时显示样本数，不报告稳定 p99。
5. 显示验收先确保目标进程、有效活动区间、事件关联及工具诊断正确，再建立 hitch 基线。schema 缺失、事件为空、trace 超时或结果缺失均为未验证，不能按 0 卡顿通过。
6. 任何内容丢失、阅读位置／草稿／折叠状态回归都阻止交付。性能数据若跨重复运行持续超出基线波动范围，需要附归因与取舍说明才能接受；未完成基准校准时不编造一个普适的百分比阈值。
7. 长测应在短测通过后再做，用固定的阅读／切换／输入周期观察 30–60 分钟趋势；有界的视图、任务和观察者数量，以及静置后的资源回落分别记录。不能用延长录制替代一个尚未明确的问题。

## 当前范围与后续

[首轮基线与证据](2026-09-23-native-acceptance/REPORT.md)：正式组件短回放已运行三次，帧事件归属和关联可用，但 **hitch 检测校准未通过**。注入的 120ms 主线程停顿对应约 167ms 的帧生命周期结束时间间隔，Instruments 的 app hitch 表仍为 0。采集器对此返回失败；普通 frames 命令成功只代表取得可用事件，不代表流畅度通过。解释清楚该工具行为并通过正向校准前，不启用“0 hitch”自动放行。帧生命周期区间及其结束时间间隔均不能直接称为屏幕 FPS。

此入口首先覆盖正式搜索弹层、全部会话页、侧栏选择及正文的短时回放。已有 `run-navigation-check.py` 继续负责完整混合历史覆盖、搜索选区、缩放与前插锚点等定向检查。每个探针只回答一个未解决的问题；fixture 和正式组件变化时一起检查入口代表性。

发现停顿后，依次确认执行路径、捕获具体长任务、做最小修复、重放原场景和相关正确性检查，再本地提交。新行构造／挂载／布局的细分与流式全工作台更新是后续工作，不能以本验收入口的完成替代产品优化。
