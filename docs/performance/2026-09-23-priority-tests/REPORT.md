# 跨行布局与导航响应测试 — 2026-09-23

**跨行时创建、挂载和测量新宿主仍是首要优化方向；正式搜索面板必须先补齐代表性测量。** 本轮没有修改产品行为，也没有证明整体 App 已变流畅。新增测试记录回答两个问题：慢滚动步是否伴随新宿主创建；搜索自身是否触发正文创建／测量，还是与滚动工作叠加。

## 条件与版本

- 独立工作树 `codex/perch-stutter-map`，开始时干净，候选产品版本 `f24045d`。已 fetch，最新 `origin/main` 为 `9743a5a`，比候选的上游基线 `ae53ec4` 多一项新回复按钮描边修正。为固定比较条件，本轮未改动基线或其他工作树。
- macOS 26.6.2 (25G83)、Apple Silicon、18 GiB、Xcode 27.0／Swift 6.4，`scripts/build-navigation-preview.sh`，Release `-O`。500 个合成目录会话、每个加载会话 200 轮混合消息、8 个缓存命中切换目标，1180×600pt 宿主／600pt 阅读视口。不访问用户会话、SSH 或附件服务。
- 两次原入口阅读和 roundtrip 重放使用同一二进制；随后仅在测试中接入已有阶段计数器及静止搜索对照，产品源码 SHA256 保持 `f59579d546178f5c52d130f9ba2e246085e46dc8e29f425eed206e825bff31d2`。两种 fixture 的指纹分别保留，不能作为产品优化前后 A/B。
- 逐步耗时包含程序化滚动／本地状态更新、布局、绘制和 transaction flush，**不是屏幕帧间隔或硬件点击延迟**。Time Profiler 排除前 4 秒，inclusive CPU 样本相互包含。后台其他应用和 WindowServer 仍有负载，没有操作它们；不从跨时段差异计算加速比。

## 1. 新消息进入视口与回读

| 指标 | 原入口第 1 次 | 原入口第 2 次 |
| --- | ---: | ---: |
| 首次向下阅读 p95 | 28.59ms | 29.17ms |
| 向上回读 p95 | 26.44ms | 26.84ms |
| RSS：开始 → 向下结束 → 向上结束 | 123.84 → 150.48 → 155.39 MiB | 126.38 → 156.55 → 151.91 MiB |
| 向上过程中最大保留／挂载宿主 | 20／8 | 20／8 |
| 长历史阅读后切换：选择反馈 p95 | 45.92ms | 47.92ms |
| 长历史阅读后切换：正文可操作 p95 | 49.39ms | 51.05ms |

新增关联测量（同一回放按是否发生 `host_create` 分组，不是两个独立 A/B 场景）：

| 方向 | 无新建宿主：步数／p95 | 有新建宿主：步数／p95 |
| --- | ---: | ---: |
| 向下 | 101／5.69ms | 255／26.26ms |
| 向上 | 108／5.68ms | 247／26.96ms |

向下累计新建 517 个宿主，非缓存命中的宿主测量也是 517 次；向上分别为 506／506 次。计数累计经过整段历史，与同时保留的 20 个宿主不是同一个概念。向上读到已淘汰区域仍要重建；本次没有保留视图随历史增长的证据。这些总计也不能证明每一个具体宿主绝无重复测量。

向下阶段累计：宿主构造器 42.50ms、宿主测量 1154.84ms、Markdown parse 131.15ms、原生文本测量 198.94ms、富文本生成 52.01ms；向上宿主测量 1090.71ms。阶段有嵌套，不可相加。构造器时间不包括之后懒加载 `host.view`、挂载及 SwiftUI 图构造，不能解释为整个创建路径仅需 42ms。

实际链：`ConversationViewport.refresh → ConversationDocumentView.refreshVisibleRows → ConversationEntryController.measure → NSHostingController.sizeThatFits → SwiftUI 布局／原生文字测量`。新 Time Profiler 回放中宿主测量占主线程样本 4457／17423ms（25.6%），原生文本测量 698ms。该 trace 还包括后续往返滚动和切换，不是只包含首次阅读的精确阶段切片。

结论：优先减少新行进入时的同步视图图构造和布局工作。当前证据没有指出一条可直接删除的重复宿主测量，也不支持增加全历史缓存或预加载。上轮失败的段落合并不应以放松锚点断言重新引入。下一项实验应针对同一富文本行分开测量首次 `host.view` 实体化／挂载和 `sizeThatFits`，再选择局部改法。

## 2. 点击、搜索、会话切换

原入口两次 roundtrip 中，缓存命中正文就绪 p95 为 40.18／42.05ms；滚动中 60 次搜索更新的 p95 为 62.87／62.49ms，均没有漏过目标列表 token。

新增对照使用同样 60 次查询顺序：

| 条件 | p95 | 新建宿主／宿主测量次数 |
| --- | ---: | ---: |
| 正文静止时搜索 | 19.85ms | 0／0 |
| 搜索叠加正文滚动 | 60.92ms | 246／246 |

滚动搜索阶段累计宿主测量 485.59ms；本轮 roundtrip RSS 118.61→155.06 MiB。对照按“静止后滚动”的顺序运行，未消除顺序和预热效应，因此不从二者相减推导严格因果成本；零宿主创建／测量也不等于正文 SwiftUI body 完全没有重新求值。两条路径共 120 次更新都到达列表标记；本轮把漏更新显式升级为失败条件。

**代表性缺口：这个 fixture 不是当前生产搜索面板。**

- 回放的列表执行 `NavigationModel.scope → SessionCatalog.scope`，整条查询用 `localizedCaseInsensitiveContains`。用于验收的 `scopeToken` 还会再次计算 scope，因此本身增加开销；新 roundtrip trace 中 `SessionCatalog.scope` 637ms、`scopeToken` 433ms 的 inclusive 样本重叠，不能把这些数值原样当作产品搜索成本。
- 当前实际搜索／全部会话面板是 `SessionDirectoryView`，局部 `@State query → WorkspaceSession.matchesSearch`，分词后 `localizedStandardContains`，并维护键盘选择与可见行。这不同于 `WorkbenchModel.sessionScope` 用于其他范围筛选的路径。
- 当前正式侧栏还使用 `SidebarProjection`、任务组投影和生产 `WorkbenchModel` 的更新链；现有导航 fixture 未完整包含这些路径。

因此，本次支持“滚动时的正文工作会与输入争用主线程”，不支持“正式搜索面板每敲一个字都重建正文”，也不支持直接给正式搜索增加缓存／防抖。下一步应给真实 `SessionDirectoryView` 和 `WorkbenchSidebar` 注入隔离的固定目录数据，保留真实选择和列表更新路径，并把额外验收筛选移出计时路径；随后再衡量局部搜索、点击反馈、正文就绪及流式目录更新。

## 功能与真实窗口核对

- 两次基础阅读、阶段阅读及 Time Profiler 阅读均覆盖 200 轮与最后一项；每次到达顶部和底部。没有靠隐藏历史换取数字。
- 冷目标跳转 200／1／101／7／199／51 轮全部命中，选择处理器耗时 0.06–0.19ms，内容就绪 21.13–46.08ms；这说明选择状态改变与内容准备不是同一时刻。快速选择合并、悬浮、流式历史锚点、前插旧消息、空会话与会话切换检查通过。
- 代码、标题、中文表格搜索选区通过；缩放及会话返回均保持同一消息的 165pt 偏移。
- CUA 实际操作独立窗口：从第 1 轮向下跨 3 页，向上 2 页再向下 2 页；输入无匹配查询，列表为空而第 5 轮正文保留；中文“验收会话 2”筛选生效，点击结果切到另一会话，清空查询再返回会话 1，仍显示第 5 轮。最终截图确认正文与列表可见。本轮没有目测或帧级数据足以宣称“非常流畅”。
- CUA 初次定位受多个同 bundle ID 预览影响，改用本轮独立 `dev.perch.priorityqa20260923` 副本；中文粘贴工具曾报读取剪贴板超时，随后读回确认查询已生效，未把工具延迟当作应用卡顿。全部本轮预览和 xctrace 已退出，用户运行的正式 Perch 未操作。
- 本轮只测试 1+2，没有重做图片、草稿、IME、网络加载或长期资源验收；它们的历史结果不能算本轮新验收。没有有效的显示帧／GPU 呈现测量，也未覆盖用户真实整个工作台。

## 复现与证据

```sh
scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py reading --output .local/priority-reading
python3 scripts/run-navigation-check.py roundtrip --output .local/priority-roundtrip
python3 scripts/summarize-navigation-stages.py .local/priority-reading .local/priority-roundtrip
python3 scripts/profile-navigation.py reading --output .local/priority-reading-profile
python3 scripts/profile-navigation.py roundtrip --output .local/priority-roundtrip-profile
python3 scripts/run-navigation-check.py turns --output .local/priority-turns
python3 scripts/run-navigation-check.py interactions --output .local/priority-interactions
```

目录内保留精简结果、阶段汇总、CPU 汇总和带 SHA256 的 `evidence-index.json`。原始逐步记录、完整 CPU 栈、trace、构建日志与隔离二进制在 `.local/priority-tests-20260923/`，未纳入 Git。报告的 source commit 与构建／fixture 哈希需一起使用：新增探针构建时 HEAD 仍是 `f24045d`，测试源有本轮未提交修改。

本轮验证：隔离 Release 编译、两组基础重放、阶段对照、两份真实 Time Profiler 录制、轮次／搜索／锚点回归、CUA 窗口操作及 diff 检查。未修改产品代码，因此未重新运行完整发布构建或协议检查。仅本地提交测试与报告，未推送、合并或替换用户应用。
