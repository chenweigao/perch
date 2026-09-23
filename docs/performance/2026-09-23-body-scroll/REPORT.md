# 正文反向阅读优化（Mac mini，2026-09-23）

## 结论

同一机器、固定基线/候选二进制、三对交替回放中，向上阅读的每轮布局耗时 p95 中位数从 22.98ms 降到 15.59ms（约降低 32.2%）。首次向下阅读为 19.00ms → 19.06ms；现有样本没有显示相同规模的前向收益。这里计时到 layout/display/CA flush，**不是 FPS、触控板端到端延迟或已通过的帧流畅度验收**。

## 实现

正文为控制内存只保留附近的宿主视图。之前，读过的行在离开保留范围后，其宿主会销毁；向上重读时重新创建宿主，并同步执行 SwiftUI sizeThatFits，尽管该行先前已经测量过。

ConversationDocumentView 现在保存已测量尺寸和对应内容，重新进入视口时只在内容、宽度、显示样式一致的条件下为新宿主预填尺寸缓存。会话/样式变化清空缓存，移除消息时清理条目，折叠变化立即失效，实际布局回调更新尺寸。内容比较放在实际复用处，避免每次界面更新比较整段历史。没有用 160pt 占位高度推断测量是否有效。

缓存只保存当前正文的内容值和尺寸元数据，不保留额外宿主图；消息内容使用已有值语义存储。没有隐藏历史、裁掉消息或扩大宿主保留范围。

## 环境与实验

- 基线：origin/main `fadda37d63a78f68ef21b233a277c581e5c16828`；独立分支 `codex/mac-mini-body-scroll`。
- macOS 27.0 (26A428)，Xcode 27.0 (27A266a)，Swift 6.4，Mac mini M4。
- NSScreen 返回在线/活跃的 1920×1080、60Hz 显示；未确认其为实体显示器。
- Navigation Preview 固定 200 轮混合长正文，正式正文组件，Release。每轮向下 349 步、向上 348 步。正式全工作台 NativeAcceptance 另用于 CPU 采样，两种 fixture 不混算。
- 顺序 A1–B1–B2–A2–A3–B3。A/B 各自固定同一二进制；哈希及逐轮数据见 measurements.json。

| 每轮 p95，ms | A 三轮 | B 三轮 | A/B 中位数 |
| --- | --- | --- | --- |
| 向下首次阅读 | 18.276 / 19.392 / 19.001 | 19.055 / 19.065 / 18.954 | 19.001 / 19.055 |
| 向上重读 | 23.760 / 22.983 / 22.894 | 15.028 / 15.588 / 15.588 | 22.983 / 15.588 |

六轮检查均通过。向上阶段 host_measure 计数每轮 466 → 0；宿主仍然按需创建，只避免重复同步测量。所有运行最大 mounted/retained 均为 8/20。短期 RSS 只做辅助观测，不据此声称无泄漏；详细值保存在 JSON。

第一版候选逐项全量比较缓存内容，出现约 0.6–1.1ms 的前向代价，未作为最终交付。最终版改为复用时比较，以上数据全部来自最终二进制。

## 验证与限制

- 200 轮上下阅读、前插锚点、搜索选区、缩放和会话返回、流式导航与空会话、往返期间输入、图片解码检查通过。
- 附加包含本地 4K 图片的完整上下阅读通过。
- 基线实际界面滚动从末尾到第 194 轮，再反向到第 195 轮，正文、表格和代码可见；这不提供物理触控板或掉帧测量。
- 普通 Perch.app Release 构建、严格签名检查和 WorkbenchChecks 通过；生产二进制没有 NativeAcceptance/NativeDirectoryProbe 符号。实 SSH 检查因 WORKBENCH_LIVE_HOST 未设置而跳过。
- 候选同一 HistoryScroll CPU 采样得到 1,160ms 主线程权重，refreshVisibleRows inclusive 174ms、measure 67ms、NSHostingView.layout 456ms。每版仅一次 profiler 采样，作为减少同步测量的辅助证据，不当作稳定 CPU 加速比。
- 最终打开候选手动体验窗口时系统已锁定，尚未完成该版本的手动触控板检查；自动检查不替代它。
- 基线 Time Profiler 在约 3.02 秒 HistoryScroll 区间得到 1,295 个主线程采样（权重合计 1,295ms）；ConversationDocumentView.refreshVisibleRows inclusive 271ms，ConversationEntryController.measure 175ms，NSHostingView.layout 454ms。这些采样区间嵌套，不能相加或当成可实现的加速比。
- 本机 Animation Hitches 正向校准没有导出 update/frame lifetime/vsync 数据行，解析结果为 unverified。虽然 Xcode 工具可运行，帧验收仍未通过，不报告 0 hitch 成功。
- 新构建 App 初次直接启动两次未创建可用验收窗口，经正常系统打开后回放可执行。两次超时及手动介入的启动样本均未纳入 A/B。
- 原始结果、manifest、构建日志与 trace 保存在本工作树 `.local/body-scroll`；旧实验未覆盖。

## Kimi 委派试验

用户授权的源码任务由本地 Kimi Code 调用百炼 K3，约 18.7 分钟返回草案。它提出复用已测行高，但原草案以“高度不等于 160”判断有效性，且没有验证宽度/内容来源；没有原样采用。用户决定本地接手后，Codex 补齐有效性约束、减少校验开销，并完成构建和 A/B 验证。本轮委派延迟不理想，不把它作为成功的节时或节省 token 案例。

尚未推送、合并或部署。长时资源观察、物理触控板惯性/快速反向与可靠帧事件采集仍需独立验收。
