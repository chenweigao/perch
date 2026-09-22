# Perch 卡顿路径排查 — 2026-09-22

本轮定位问题，不修改产品渲染行为。最强证据指向：**频繁创建／销毁原生文本视图的主线程清理，以及新行进入视口时的同步布局**。图片首次显示也有独立的主线程解码开销。不能把所有卡顿归为 Markdown 解析，也不能以宿主数量有界证明交互已经稳定。

报告覆盖固定离线回放和真实 Mac 隔离窗口；没有操作用户的真实会话。整个生产工作台、远端加载及显示帧级验收仍有明确缺口，见后文。本轮没有“全部卡顿已解决”或“所有原因均已穷尽”的结论。

## 基线与证据口径

- 开始前检查 main、工作树、规则及既有改动；fetch 后从 `8ba9396dd4f719c413759a2e1a5e9fe0992ef42e` 建立独立 `codex/perch-stutter-map`。其他工作树和运行中的正式应用保持不变。
- macOS 26.6.2、Apple Silicon、18 GiB 内存、Xcode 27.0、Swift 6.4；Release `-O`。固定 500 个目录会话、每个加载会话 200 轮混合内容、1180×600pt 宿主、600pt 高阅读视口。会话切换覆盖 8 个缓存命中对象。
- 两版 fixture 的产品源码相同。原始版本用于时间采样；第二版仅增加可选的本地图片输入。一次无效的通知注册表探针已撤销。指纹、编译器和图片哈希见 `manifest.json`，每次报告保留其自身 build 字段。
- 数字是本地模型修改／程序化滚动至 layout、display、transaction flush 的耗时，**不是显示帧间隔、硬件点击延迟或 GPU 呈现耗时**。特别是 soak 会反复大跨度跳转，不是正常读者的匀速小幅滚动。
- Time Profiler CPU 数值来自采样；inclusive 调用栈权重相互包含，不能相加，也不是修复后可获得的加速比。自动回放的 CPU 摘要统一排除录制前 4 秒，仍不是精确的阶段 signpost 切片。
- 运行期间也观察到 WindowServer、Chrome 和会议进程有较高 CPU；不操作这些应用。绝对延迟受机器负载影响，不将不同时间、不同采样方式的数值包装成 A/B 改善。

## 具体问题与优先级

### P1：真正的文本视图销毁越过了退役预算

触发：反复从不同会话进入远处历史，持续约一分钟后进一步加重。`unprofiled-soak-result.json` 的 122.85 秒回放出现滚动 p95 406.93ms、最大 3002.49ms；这是无 Instruments 录制的压力回放，不是正常用户输入的直接延迟。

执行链：`ConversationDocumentView.refreshVisibleRows` 淘汰远处宿主／`configure` 切换会话 → `retire` 按 2ms 预算移除控制器 → SwiftUI/AppKit 延迟释放原生视图 → **后续 `__CFRunLoopDoBlocks → _Block_release → NSTextView.release/dealloc → NSTextStorage/NSLayoutManager.dealloc → _CFXNotificationRegistrarRemoveObservers`**。

证据：

- 60 秒 Time Profiler 压力回放中，通知观察者清理的叶子样本约 15,019ms，占主线程 59,627ms 的约 25.2%；每十秒采样权重从数百毫秒升至数秒。
- 另一次相同二进制的 120 秒压力回放，仅在第 65 和 100 秒附近各用 `sample` 采集 3 秒、10ms 间隔的栈。主线程分别有 264、269 个样本，通知清理的叶子样本分别为 158、163（约 60%）。见 `late-stack-summary.json`。因此该栈不是长时间 Instruments 录制才出现的现象。
- 这些窗口保留／挂载的宿主仍较少，退役队列大多是个位到二十余个。队列最终可清空，但主线程清理仍然很重。

已确认：清理是晚期停顿的重要主线程热点；当前 `retire` 的 2ms 检查没有覆盖延后到 RunLoop 执行的全部销毁工作。尚未确认：通知注册表为何使清理成本增大、是否存在框架内部残留，以及是否需要改变原生文本视图复用方式。**没有通知数量或泄漏证明，不称作已确认的 observer leak。**

下一项最小实验：在同一内容和窗口下，对照每个跨行动作创建／销毁的 `ReplyTextView` 数量及之后的 RunLoop 清理时间，再验证一种减少重复原生文本视图生命周期工作的局部方案。保持文本选择、链接、代码和表格行为；不保留全部历史视图，也不通过隐藏消息减少工作。

### P1：跨行时同步创建和测量宿主

触发：新内容进入视口、大跨度反向阅读、冷目标跳转。8pt 小幅滚动 1200 步的 p95 为 2.28ms；完整首次向下／向上阅读为 31.44／34.98ms；随后大跨度往返为 52.17ms。它们是不同场景，不能算前后加速比。

执行链：滚动 bounds 变化 → `ConversationViewport.refresh` → `refreshVisibleRows` → `ConversationEntryController.measure` → `NSHostingController.sizeThatFits` → SwiftUI 子布局／`ReplyTextView.measure`。首次进入或已淘汰的行还会重新创建视图及解析 Markdown。

完整阅读 trace 中，宿主 measure 包含 4,663ms 主线程采样（21.3%），原生文字 measure 1,139ms（5.2%）；Markdown parse 806ms（3.7%）。真实手工滚动／切换的 25 秒 trace 也采到宿主 measure 154ms。这支持先处理布局／生命周期路径，不能根据“消息是 Markdown”就先增加全局解析缓存。

现有同行范围快速返回和小尺寸缓存有效；已经淘汰的宿主不会因“曾经读过”而免费恢复。下次优化需分别重放小幅滚动、首次进入、回读和快速反向四种情况。

### P2：大图在主线程提交时才实际解码

触发：切到含 4096×3072 PNG 的会话。使用仓库内合成图片，没有网络或真实用户附件。

实际窗口显示图片；手工 Time Profiler 记录到主线程 `CA::Transaction::commit → CA::Layer::prepare_contents → CA::Render::prepare_image → IIOImageProviderInfo → PNGReadPlugin → png_do_read_transformations`。PNG 像素转换累计 29ms 样本；这是整段采样累计值，**不是单次显示延迟**。

`KimiAttachmentView` 用 `NSImage(data:)`，视图虽限制显示到 600×340pt，仍可能在提交阶段解码原始大图。下一步对照与显示尺寸匹配的 ImageIO 缩略图／解码时机，核对清晰度、原附件下载和阅读锚点。慢网络图片、JPEG、多图和图片缓存生命周期尚未覆盖。

### P2：搜索和列表更新叠加正文工作

触发：500 个会话目录中连续搜索，同时滚动正文／切换会话。60 次搜索状态更新未丢失，但显示提交 p95 为 65.70ms；归档／任务组切换约 33.86／34.89ms，回到工作台约 10.04ms，会话正文就绪约 41.51ms。

`SessionCatalog.scope` 在主线程遍历、拼接字段并执行 `localizedCaseInsensitiveContains`。roundtrip trace 中该筛选路径占约 336ms（6.3%），正文宿主 measure 约 686ms（12.8%）。目录筛选是次要可行动热点，不能把全部搜索延迟归因于它。fixture 使用生产筛选函数，但列表容器和真实 WorkspaceStore 的连接／发布链不是完整生产工作台。

### P2：窗口缩放后仍有阅读偏移

同一消息行在变窄前后偏移由 165pt 变为 168pt，触发原有 `resize anchor` 断言。切换其他会话再返回保持 168pt；前插 20 条旧消息保持同一行 33→33pt。见 `interactions-interaction-detail.json`、`anchor-result.json`。

这是已复现的阅读稳定性问题，不是整个 App 卡顿的原因；本轮不混入未经验证的宽度修正。

## 场景覆盖

| 场景 | 本轮结果 | 边界 |
| --- | --- | --- |
| 首次／完整历史阅读 | 200 轮和末尾覆盖通过；上下读后 RSS 131.53→149.70→153.13 MiB | 程序化阅读，无帧率结论 |
| 小幅／大跨度／反向滚动 | 已分别测量；真实窗口快速反向后显示表格和代码 | 手工动作时间不作为延迟 |
| 重复切换与视图保留 | 60 秒、120 秒压力回放；明显晚期清理热点 | 不构成长期无泄漏验收 |
| 输入、历史位置下 10Hz 流式 | 中文粘贴、ASCII 草稿、A/B 独立草稿；流式至 300 步，历史仍在第 198 轮 | 中文由粘贴验证，不是 IME 组合输入验收 |
| 工具展开／返回会话 | Bash 输入和结果展开，切回 A 保留展开、草稿和阅读内容 | 原生窗口行为验证，未获得有效 animation hitch ratio |
| 回到最新消息 | 实际按钮显示第 201 轮及完整 300 个合成片段 | 不访问远端任务 |
| 图片 | 4K PNG 实际显示，主线程解码栈已捕获 | 没有远程下载／多图内存验收 |
| 搜索跳转 | 代码、标题、中文表格选区均通过 | 真实数据规模和服务器搜索不在内 |
| 轮次导航 | 冷目标、快速选择合并、悬浮、流式锚点、空会话通过 | 就绪包含布局和等待，非硬件点击延迟 |
| 前插历史／窗口缩放 | 前插通过，缩放失败 3pt | 偏移原因需继续细化 |
| 空闲／流式压力 | 隔离窗口 8 秒空闲约 0.18% 单核 CPU；无限速事件压力约 113.56 events/s | 压力驱动主动占满 CPU，不能当成正常 10Hz 流式负载 |
| 正式 App／SSH／终端／生产启动 | 未形成受控验证 | 正式 App 来自其他任务并在期间更换进程；首次只读 attach 因 PID 已退出而失败，不操作真实会话 |

## 工具失败与未确认项

1. Xcode 27 默认 Swift Build 改变了对象文件布局，原预览脚本找不到 `WorkbenchCore.build/*.o`。显式指定与脚本匹配的 SwiftPM native 构建后通过。native 构建系统已被 Swift 标记 deprecated；这是本轮诊断入口的有限适配，不是产品性能修复。后续应整体迁移独立预览脚本至新布局，不添加自动猜测路径的 fallback。
2. `xctrace` 对断言失败的 fixture 返回 54，但仍保存 trace。录制脚本现保留并导出这种失败结果，最后仍返回失败；不把 trace 文件存在当成测试通过。
3. SwiftUI 开启 layout tracing 报 `Cannot enable layout tracing on an unsupported device`。虽然保存了更新表，首次 body 还出现异常长的追踪区间；这些数据标记为不用于性能判断，没有可靠布局因果图或生产启动时间结论。
4. Allocations 启动目标停在 suspended 状态，未产生有效结果；只终止本轮 recorder 和它创建的测试进程。没有对象分配／泄漏结论。
5. Animation Hitches 的 90 秒录制进入长时间后处理，超过七分钟、约 70% CPU，并生成约 25GiB 未完成 trace。终止本轮 recorder、删除其不可用生成物，保留错误日志和尺寸清单；不继续占用本机资源，也不声称测得掉帧率。下一次应先验证一个数秒的最小捕获或匹配工具／系统版本。
6. `NotificationCenter.default.debugDescription` 只返回单行对象描述，不能统计注册数。探针已撤销，失败 patch 和报告保留；35 bytes / 1 line 不是观察者数量。
7. CUA 有动作已经生效但返回 AXError.failure、粘贴超时、窗口定位暂时失效的情况，均读回确认。CUA 的调用耗时不计入应用指标；退出后查询窗口曾重新启动 fixture，随后再次退出并通过进程检查清理。

完整生产工作台、后台连接发布、远端加载更早消息、真实终端输出、中文输入法以及 frame presentation 是剩余验证入口。现有 source 支持 Native 解码已离开 main actor；尚未用受控真实连接 trace 验证端到端响应。不能用本轮离线回放替代这些项。

## 最值得做的下一步

优先处理 **ReplyTextView 生命周期与延迟清理**，同时记录跨行同步测量。先用无采样器的相同压力回放和后半段短栈证明改善，再用实际小幅滚动、反向、选择文字、展开工具和会话返回核对体验。随后处理大图解码。目录筛选和 3pt 锚点问题各自单独修复，避免同时修改导致无法归因。

帧级工具链恢复后，按 Apple 的 [SwiftUI 性能定位流程](https://developer.apple.com/videos/play/wwdc2025/306/)关联更新原因和主线程栈，并依据 [响应性与 hitches 文档](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)核对显示期限。不能用一次源码审查给出“已达到 Apple 原生最佳实践”的总体认证。

## 复现与交付

```sh
swift build --build-system native -c release --target WorkbenchCore -j 2
scripts/build-navigation-preview.sh
python3 scripts/profile-navigation.py reading --output .local/replay-reading
python3 scripts/profile-navigation.py small-scroll --output .local/replay-small
python3 scripts/profile-navigation.py roundtrip --output .local/replay-roundtrip
python3 scripts/profile-navigation.py interactions --output .local/replay-resize
# 原有缩放断言应失败；trace 和失败报告均保留。
python3 scripts/run-navigation-check.py soak --seconds 120 --output .local/replay-soak
NAVIGATION_JOINT=1 NAVIGATION_IMAGE_FIXTURE="$PWD/Tests/Fixtures/stutter-map-4k.png" \
  'build/Navigation Preview.app/Contents/MacOS/NavigationPreview'
```

不要并行录制或边编译边比较性能；固定内容、尺寸、编译器和二进制。`profile-navigation.py` 的输出目录必须是新的；压力回放和手工联合窗口分开。工具原始 trace、完整栈、执行日志保留在任务工作树 `.local/stutter-map/`；筛选后的 JSON 证据在本目录。

本地提交诊断脚本、可选图片 fixture 和报告；没有改产品源码，没有推送、合入 main 或替换用户应用。Core 和隔离 Mac 预览构建通过；脚本在真实录制／失败导出路径中验证。本轮不宣称全产品回归、线上性能改善或发布完成。
