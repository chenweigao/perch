# SwiftUI Expert 接入与滚动归因

本轮安装 SwiftUI Expert，创建并验证本机 `perch-performance` 技能；以最新主线 `c2d330e` 排查滚动。没有采纳生产提速改动。保留验收应用的阶段标记和时钟信息，撤掉未证明整体收益的挂载顺序候选。

## 范围与证据

- 独立 worktree/branch：`perch-scroll-skill-20261012` / `codex/perch-scroll-skill-20261012`。
- 当前主线已包含 PR #108 的准备结果复用、行高度缓存和批量几何更新；不是之前 c2affca 的同一个性能基线。
- Release `scripts/build-navigation-preview.sh`，实际生产正文组件，200 turns、500 sessions；请求 120 Hz 程序化滚动。显示器实际刷新率未记录，不将请求频率当成实际显示频率。
- `fast-scroll` 包括首次向下、整段向上返回、局部往返；每步包含布局、绘制、事务提交。数值不是 FPS、触控板输入延迟或完整渲染链路耗时。
- 所有实验在独立验收应用进行，不读取真实远端会话；另一个原生流畅度工作区的未提交修改未动。
- 来源、编译器和内容摘要见 `provenance.json`；原始 trace/XML/log 留在 `.local/skill-scroll-investigation/`，不提交二进制。每次未采样运行的构建/二进制摘要、阶段详情见 `runs.json`。

## 新技能的实测边界

使用 SwiftUI Expert 的 `record_trace.py`、`analyze_trace.py`；这不是只阅读技能后的推荐。

1. 旧已知停顿 trace 被成功读取，最严重 hang 约 175 ms，但空 hitch 通道仍被报告成 0 hitches。
2. 当前 SwiftUI 模板录制 11.15 s，只有 NavigationPreview 的 CPU 数据可用。Instruments 明确警告 `Trace file had no SwiftUI data`。分析器却把 SwiftUI 更新、原因边、hitches 均报告为 available/0；不能据此确认没有更新或掉帧。
3. 当前 CPU 数据每个样本权重 0.1 ms，不是技能诊断说明所假定的 1 ms。不能套用其固定采样覆盖率阻塞分类。
4. 增加 Points of Interest 后，目录含多个 os-signpost 表。三个阶段在分析器输出中各重复一次；按进程、signpost ID、起止时间去重后再归因（`trace-phases.json`）。

`perch-performance` 已加入上述判读约束，不修改上游技能。Apple 的[性能指南](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)描述如何关联更新与 CPU 时间；本轮无法采集的 SwiftUI/帧通道仍明确留空，不用 CPU 代替。

## 三次不挂采样器的基线

每次均通过、无缺失可见行、最终文档高度相同。

| 操作 | 单步中位数范围 | 单步 P95 范围 | 每次新建 controller |
| --- | --- | --- | --- |
| 首次向下 | 12.63–13.80 ms | 18.21–21.15 ms | 477 |
| 整段返回 | 11.80–13.17 ms | 19.63–20.64 ms | 466 |
| 局部往返 | 0.96–2.11 ms | 2.00–4.64 ms | 0 |

返回阶段没有显式 `host_measure` 工作，却仍创建 466 个 controller。已缓存行高度不等于保留排版对象，也不能消除挂载后的框架布局。局部往返没有复现相同程度的工作负担，不能据此否定另一台机器上同段滚动的体感问题。

## CPU 栈归因

独立的 `summarize-time-profile.py` 读取原始 XML，按去重后的三个 signpost 窗口统计（`*-cpu.json`）。所列包含式栈时间会重叠，不相加。

- 首次：主线程采样 2321.4 ms / 阶段 2354.7 ms；`refreshVisibleRows` 栈约 1099.9 ms，显式行测量约 346.6 ms。
- 返回：主线程采样 2135.1 ms / 阶段 2191.0 ms；`refreshVisibleRows` 栈约 721.2 ms，显式行测量仅 0.4 ms。框架更新与布局仍明显存在。
- 局部：主线程采样 618.0 ms / 阶段 2236.8 ms；正文刷新栈约 25.9 ms。不能把其余框架工作未经归因全算到正文。

进一步追到返回阶段的 Unicode 断行栈：

`NativeAssistantStackView.update → NSView.setSubviews → _recursivelyInvalidateCachedContentStyle → NSTextView.setNeedsDisplayInRect → NSLayoutManager/NSParagraphArbitrator → ICU break iterator`

`u_strFromUTF8WithSub` 叶子累计约 140.8 ms，其中 1388/1408 样本包含正文刷新路径。这是内容挂载触发实际文本排版的证据，不是 Markdown 解析；仍不是单个掉帧的因果证明。原始样例见 `utf8-stacks.json`。

## 挂载顺序对照：不采纳

新假设：先挂空的 block view，再填文本，以避免设置父视图时对已填文本提前排版。不同于之前被否决的 `subviews=` 改成逐个 addSubview。

仅验收编译下加入开关，同一个二进制按 off/on/on/off 顺序运行；候选原生 `assistant-rows` 一致性通过，四次 fast-scroll 均通过，无缺失行，文档高度一致。候选保存为 `rejected-mount-before-content.patch`，未保留在生产源文件。

两次/臂的平均累计阶段时间：

| 阶段 | 关闭 | 开启 |
| --- | ---: | ---: |
| 首次助手行创建 | 171.10 ms | 58.86 ms |
| 首次 host view 获取 | 142.79 ms | 222.57 ms |
| 返回助手行创建 | 146.78 ms | 33.68 ms |
| 返回 host view 获取 | 172.68 ms | 304.53 ms |
| 返回正文 range 刷新 | 635.57 ms | 650.40 ms |

创建阶段看似明显变快，但挂载阶段增加了相近工作。首次滚动中位数 off 11.88–12.40 ms / on 12.28–12.47 ms；返回 off 11.49–11.69 ms / on 11.25–11.32 ms；局部没有一致改善。少量变化不能证明稳定整体收益，停止推广这个候选。

## 下一项有依据的实验

针对跨出保留窗口后的文本行生命周期做小范围试验：保持已排版文本与其容器的稳定关系，减少拆装造成的失效；先限定一种原生行及内存预算，再对照首次、整段返回、局部往返和原生交互。不要直接扩大整行宿主缓存，也不要仅把工作移到另一计时阶段。

真实触控板与 app-owned 帧数据仍未验收。本轮结论是定位到可实验的排版/挂载路径，并否决一个只有局部指标漂亮的方案；不能宣布滚动问题已解决。

## 最终验证

候选已从生产源文件完全撤销。最终 Release 重建、fast-scroll 功能验收及签名检查通过（`final-check.json`）；Perch 技能通过 skill-creator 格式校验。最终代码差异仅为 Navigation Preview 的 8 行阶段诊断，另附本报告与证据；未推送或部署。

后续实验已单独记录在[原生用户消息直接承载行视图](../2026-10-12-direct-user-root/REPORT.md)。以上未采纳生产优化的结论仅指本阶段。
