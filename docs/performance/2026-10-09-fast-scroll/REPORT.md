# 快速正文滚动诊断（2026-10-09）

## 结论

快速滚动尚未解决，也没有证据表明已经到达无法优化的极限。此次把首次扫读、已读历史整段返回、同屏小范围往返分开测量。行高缓存避免了重新调用 sizeThatFits，但整段返回仍重建466 个 SwiftUI 行宿主和 968 个原生文本视图。这个生命周期开销值得继续处理。

两个架构诊断均没有直接进入生产：无限保留已读宿主能明显改善重读，但内存翻倍且首次扫读变慢；直接由 AppKit 管理滚动和文档尺寸能减少首次扫读开销，但没有稳定解决重读。下一步应以有界的原生行复用和历史正文渲染为实验边界，配合单一的文档尺寸/滚动位置管理；仅替换外层 ScrollView 或引入 TCA 都没有本轮证据支持为充分修复。

## 可复现基线

- 基于合并后的 main `d0a09bf89f98079e899290d376d1d343a8901e64`，分支 `codex/perch-fast-scroll`。
- 同一 Mac mini，Release Navigation Preview，正式正文行组件，固定 200 轮混合历史和 500 个目录条目。不是完整联网工作台，不联系真实 Agent。
- 新 `fast-scroll`：首次向下每步一屏，随后整段向上每步一屏，最后在顶部 0–288pt 之间每步 24pt 往返 240 次。默认请求 120Hz 调度，允许 60Hz 等其他节奏。
- 每步记录从设置 clip origin 到主队列回调、layout、display、CA flush 的墙钟时间。调度延迟另记；不累计追赶欠下的帧。它不是 FPS、物理输入延迟或 GPU 呈现耗时，不能据此计算真实掉帧率。
- 下读以更新后的文档末端连续稳定三次为终点，上读必须到顶部；检查可见行挂载。最终所有对照文档高度为 99,785pt，保留宿主数和 RSS 另记。大步滚动检查不替代逐轮全文覆盖检查。
- 最初 60/120Hz 探针使用旧的单次末端判据，不纳入下表。下表所有运行均使用修正后的判据。

## 诊断一：行宿主生命周期

同一固定二进制依次运行 bounded → all → mounted → bounded；下表为每次运行 p95，单位 ms。`all` 只保留已经创建的宿主，不提前创建行；离开视口仍卸载。`mounted` 连卸载也取消。两者是诊断上界，不是可发布的缓存策略。

| 模式 | 首次扫读 | 整段返回 | 同屏往返 | 返回后的 RSS | 保留宿主 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 原实现，第 1 次 | 17.66 | 15.99 | 5.60 | 164.97MB | 15 |
| 全部保留、离屏卸载 | 23.63 | 6.62 | 6.68 | 369.91MB | 480 |
| 全部保留、保持挂载 | 49.63 | 14.88 | 11.20 | 339.27MB | 480 |
| 原实现，第 2 次 | 22.40 | 16.27 | 6.17 | 164.69MB | 15 |

这支持“减少重读时的宿主重建可能有较大收益”，不支持“扩大缓存即可解决”。首次排版仍需单独处理，保持全部行挂载还会明显增加持续布局开销。RSS 只是一轮结束时的辅助采样，不是泄漏判定。

## 诊断二：直接管理原生滚动容器

同一固定二进制依次 native → swiftui → native。原型继续使用正式的 ConversationDocumentView、行宿主、文本渲染、测量与有界缓存；把文档高度直接提交给 NSScrollView 的 documentView，去掉 SwiftUI 中转高度状态。列宽、12pt 顶部留白和总高度与基线相同。

| 模式 | 首次扫读 p95 | 整段返回 p95 | 同屏往返 p95 |
| --- | ---: | ---: | ---: |
| 原生容器，第 1 次 | 15.97 | 15.21 | 6.35 |
| 现有 SwiftUI 容器 | 18.27 | 15.81 | 6.85 |
| 原生容器，第 2 次 | 15.84 | 16.62 | 6.83 |

原型未实现轮次导航浮层、跟随末尾、分页、待审批/待输入控件和完整会话生命周期，故不能把结果解释为生产等价的加速比，也不能发布。它只支持优先试验单一几何管理边界；即使在这个更简单的原型中，重读开销依然存在。它未针对刷新闪烁做修复验收。

## 已合并 PR #81 的额外回归证据

本轮检查到 PR #81 已合入，但 GitHub Actions run `37879564030` 的 Native build and interaction regression 失败于 `native-kimi-refresh`。本地通过不等于该合并版本全部 CI 通过。

CI 记录最后一次切换中：正文已显示；约 293.68ms 时内部文档高度从 74,515pt 缩为 71,075pt，而外层 clip origin 仍为 73,905pt，实际可见行为空；约 319.62ms 才恢复到 70,465pt。`viewWillDraw` 补挂载无法处理视口整个落在新正文范围之外的情况。不能通过放宽无空白断言消除这个失败，也不能据此认定快速滚动和切换闪烁只有同一个根因。

完整失败记录保存在 `pr81-ci-refresh-failure.json`。该问题仍开放，未在本轮声称修复。

## 改造边界与验收

建议下一项可发布改造针对已完成历史消息：用有界、可复用的原生行承载文本和布局，避免按消息反复销毁/创建完整 SwiftUI 图；流式尾部和复杂交互必须显式保留状态隔离。AppKit 的 [NSCollectionView 复用接口](https://developer.apple.com/documentation/appkit/nscollectionview/makeitem(withidentifier:for:)) 提供现成机制，但是否选它、NSTableView 或现有文档内复用，仍需与混合行高和文本选择行为一起对照。换框架本身不是性能结论。

同时应统一文档高度、行位置和 clip origin 的提交，覆盖缩短正文、展开、分页、底部交互控件；不要仅把滚动位置强行夹到正文底部，否则会破坏正文下方待审批控件的访问。

候选必须同时改善首次和重读，并通过全文覆盖、链接/复制/搜索、同 ID 更新、展开、缩放、阅读锚点、会话切换以及刷新无空白检查，再到用户反馈的另一台电脑验收实际触控板体验。本机同屏小范围往返没有稳定复现同样大的开销，不能否定用户另一台电脑上的体感。

## 复现

正式保留的变化是 `fast-scroll` 回归入口和报告，生产 Sources 已恢复。实验代码只保存在 `diagnostic-probes.patch`，应用到本诊断提交可重建容器对照版本。`results.json` 保留逐步时间、嵌套阶段计数、源/二进制哈希和环境配置；不同实验版本不要混作同一二进制。报告内本地路径已规范化为 `$WORKTREE`；原始回执保留在本机 `.local/fast-scroll`。

```sh
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py fast-scroll --scroll-hz 120 --output .local/new-fast-scroll
# 在单独实验 checkout 中应用 diagnostic-probes.patch 并重新构建后：
NAVIGATION_HOST_RETENTION=all python3 scripts/run-navigation-check.py fast-scroll --output .local/new-retention
NAVIGATION_HOST_RETENTION=mounted python3 scripts/run-navigation-check.py fast-scroll --output .local/new-mounted
NAVIGATION_SCROLL_CONTAINER=native python3 scripts/run-navigation-check.py fast-scroll --output .local/new-native
```

撤回探针后，快速滚动、200 轮全文阅读、文本交互检查通过；22 项性能工具测试、独立生产构建及 WorkbenchChecks 通过，结果见 `validation.json`。尚未推送、创建 PR、合并或部署。本轮产出是可复现诊断和架构对照，不是已交付的滚动修复。
