# 正文刷新与快速滚动修复（2026-10-09）

## 本轮交付

修复已经观察到的正文几何问题：刷新缩短后，旧外层高度使视口落到正文之外；刷新变长后，新进入视口的行晚一个回调才挂载。同时修复冷行测量时自动锚点覆盖显式导航目标、导致跳回顶部的问题。普通文本用户消息增加有界的原生排版路径，减少滚动经过这些行时的 SwiftUI 图构建。

最终代码通过 5 轮 `kimi-refresh`，共 30 次切换、1,800 个布局样本：首次显示后空白为 0，首次显示后的可见区域缺行为 0（初始隐藏阶段的样本单独统计）。正常切换、原生详情生命周期、分页、待审批/待输入的工作区检查通过。这里验证的是已复现路径；尚未在用户另一台电脑上验收实际触控板体验。

## 为什么这样改

`ConversationDocumentHost.sizeThatFits` 已返回原生正文高度。再用异步 `@State` 高度包一层固定 frame，会让新原生正文和旧外层文档同时存在。现在高度通知只触发重新测量，不再形成第二个高度约束。

仅移除固定 frame 的中间候选仍出现一次增长后的缺行：clip 已移到新末尾，最后一行未挂载。最终候选在 clip bounds 通知内同步补齐可见行；导航通知继续合并，保留相同行范围的快速返回和 `viewWillDraw` 检查。没有强行把视口夹到正文底部，正文之后的交互控件仍可访问。

普通用户文本行使用 `NativeUserMessageView`，共享现有 Markdown attributed string、每组最多八个段落、原生文本复用池、链接/文件路由和文本测量。只接管单个 text part、仅含非空普通段落的用户消息。代码、标题、表格、附件、运行上下文、其他消息类型和 RTL 布局沿用 SwiftUI。同行内容变复杂或变回普通文本时，外层行身份保持不变。原生行池上限 16，每个回收行最多保留八个已清空文本容器。

原来的 `text_create` 指标记录创建入口调用，已有 NSTextView 池会复用其中多数对象；它不是新对象分配计数。历史诊断报告已补正该措辞。这里主要减少的是 SwiftUI 图构建和排版工作。

## 固定二进制对照

基于 main `343795b`，此前诊断提交重放为 `9628dd5`。生产正文基线与上一轮 main `d0a09bf` 相同；此次 main 新增的是 Kimi 手动重启提示，不进入 Navigation Preview。

同一 Mac mini、macOS 27.0.1、Release、200 轮混合正文。顺序 A1–B1–B2–A2–A3–B3，两个固定二进制，测量期间未并行构建或运行其他夹具。采用包含最终导航修复的 `final-ab-*` 运行，替换中间候选的测量。哈希、环境与逐步数据见 `measurements.json`。下表是每轮指标的三轮中位数；累计时间为步骤测量之和。

| 场景 | 累计处理时间，前 → 后 | 单步中位数，前 → 后 | 单步 p95，前 → 后 |
| --- | --- | --- | --- |
| 首次整段扫读 | 2,039 → 1,870ms（约 -8.3%） | 11.89 → 10.77ms | 19.47 → 17.08ms |
| 已读历史返回 | 1,746 → 1,726ms（约 -1.1%） | 10.05 → 9.53ms | 15.89 → 16.17ms |
| 同屏小范围往返 | 700 → 360ms | 2.78 → 0.92ms | 5.99 → 3.87ms |

首次扫读有有限改善；已读返回累计时间接近、p95 略高，不能认定稳定改善。同屏往返三轮累计范围为前 258–719ms、后 221–705ms，波动很大、范围重叠，不能用中位数的下降声称该症状已解决。返回阶段 RSS 中位数约 163.53 → 166.33MB，不使用上一轮保留全部历史宿主的方案。首次/返回分别 168/166 步，各版本总文档高度均为 99,785pt。

这是主线程上程序驱动滚动到 layout/display/CA flush 的墙钟时间，包含等待，不是 CPU 采样时间、FPS 或实际掉帧率。120Hz 是夹具请求的调度节奏。复杂助手消息依然走原有渲染器，性能不能整体收尾。

## 回归与边界

- `user-rows`：16 组真实文字排版对照，700/340pt 列宽、深浅色、短文/长文/跨组段落，行高和所选 glyph 位置差均为 0；链接属性和跨段 Unicode 复制通过。
- `reading`：200 轮完整上下阅读通过；`interactions`：搜索、同 ID 内容变化、缩放、会话返回通过，新增普通文本 → 代码块 → 普通文本的同一行切换检查。
- `anchor` 前插阅读位置、`paragraphs` 的分组/流式身份/选区检查通过。
- `kimi-refresh` 五轮、`kimi-switching`、`detail-lifecycle`、`paging`、`workspace` 通过。未调用真实远端服务。
- 独立生产构建、严格签名、WorkbenchChecks、22 项性能工具测试通过；可选 live SSH 检查未设置目标，跳过。
- 展开检查捕获了冷行导航回退问题：显式跳到 `thinking:disclosure-body:0` 后，测量新行时保存的旧尾行锚点（offset -356）覆盖目标，恢复到 y=0。显式 reveal 现在先保存目标位置，自动高度锚定不能覆盖已有恢复意图。夹具也等待原生 navigator 的 session 匹配，并要求操作前真实行已挂载；没有放宽行高、内容高度和阅读位置断言。最终展开检查记录在 `validation.json`。
- `user-rows`、`fast-scroll`、`turns` 和两种展开回归已接入 macOS functional CI；本轮未推送，不能把本地通过写成 hosted CI 通过。

原始运行位于本机 `.local/scroll-fix/`。`validation.json` 保存运行状态、来源和原始结果哈希。性能对照数据来自无并行构建的独立运行；部分纯功能检查与生产构建同时进行，其耗时不作为性能结论。

## 复现

```sh
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py user-rows --output .local/new-user-rows
python3 scripts/run-navigation-check.py fast-scroll --output .local/new-fast-scroll
python3 scripts/run-navigation-check.py interactions --output .local/new-interactions
python3 scripts/run-navigation-check.py disclosure --disclosure-context --assert-atomic-disclosure --output .local/new-disclosure
bash scripts/build-native-acceptance.sh
python3 scripts/run-native-acceptance.py --mode kimi-refresh --output .local/new-refresh
```

下一步仍需在用户反馈的机器上确认快速滚动和刷新体验；新的渲染扩展应继续以行为一致性和固定二进制性能对照为准，不能因本轮数据通过就全面迁移复杂正文。
