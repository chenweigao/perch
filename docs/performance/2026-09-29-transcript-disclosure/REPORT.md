# 长对话滚动与展开：几何交接修复

当前优先处理正文。隔离验收发现并修复了一个展开时的中间布局跳动；剩余首次布局
和展开成本仍可优化，尚不能认定体验已足够，也没有证据表明瓶颈无法优化。
侧栏 NSTableView 原型的结果另见 [对照报告](../2026-09-29-sidebar-renderer/REPORT.md)。

## 已定位并修复

基线连续两次在第一次展开 Bash 时失败：标题临时偏移 -949pt，下一次采样恢复。
补充几何探针后的第三次基线同样失败。失败样本显示：

- 原生正文已经变为 3625pt，而外层滚动文档仍为 1769pt；下一次才变为 3668pt。
- 滚动位置始终为 595pt，目标行在正文中的 y 始终为 663pt。
- 正文在宿主中的原点从 -1532pt 回到 -583pt，差值恰为 949pt。

这次跳动来自高度交接期间的默认居中，并非滚动偏移本身改变。原生正文行更新后，
外层 SwiftUI 的 measured height 延后发布；居中会把正文移动半个高度差。
产品修复仅把这个外层 frame 设为顶部对齐，保留既有阅读恢复与行虚拟化机制。

候选三轮共 36 次 Bash／Thoughts 展开和收起，所有采样的标题漂移均为 0pt，
内容高度与原生行高度一致。另有无前后文的 12 次边界回放通过。
测试现在在断言前保存几何样本，失败时也能定位中间状态。

## 当前耗时与瓶颈范围

同一候选 Release 二进制重复三轮；下表是每轮统计的中位数，单位 ms。
每次滚动计时止于 layout/display/CA flush，不是显示帧率。

| 场景 | median | p95 | 范围 |
| --- | ---: | ---: | --- |
| 首次向下阅读 | 9.48 | 18.39 | 每轮 335 步，覆盖全部 200 轮和末尾 |
| 向上重新阅读 | 6.50 | 14.86 | 每轮 334 步，保留宿主数量受约束 |
| 8pt 小幅往返滚动 | 0.46 | 1.50 | 每轮 1200 步，最大约 22ms |

小幅滚动只遍历开头约 4792pt，不能代替完整阅读；完整阅读单独检查全部 200 轮。
它说明留在相同行内通常便宜，跨入新内容仍可能超过一个 60Hz 帧的时间预算，
但不能据此计算实际丢帧率。

候选展开的首个已提交布局约 34–67ms，收起约 10–18ms。修复消除了几何跳动，
没有宣称展开变快。输入是 2400 行，但本次只点击第一层披露，生产组件实际展示
4000 字符预览；**没有点击“显示完整内容”**，不能把结果描述为完整 2400 行展开。
披露夹具仅含目标行和前后各 45 行上下文，和 200 轮阅读夹具分开。

基线完整向下阅读的分阶段计数：477 次行首次测量累计约 722ms，行几何重建累计
约 5ms。Markdown 解析约 115ms、文本测量约 207ms；这些阶段相互嵌套，不可相加。
当前证据不支持优先重写行索引，也不支持把全部成本归为 Markdown 解析。

候选另做一次 Time Profiler 展开采样，排除前 4 秒后得到 989 个主线程样本。
`NSHostingView.layout` inclusive 263ms，行 measure 42ms；文本字体映射也出现在热点。
夹具本身的遍历/证据写出占有明显样本（rows 80ms、document 查找 40ms、写出 66ms，
均为 inclusive），所以不能把整段 CPU 统计全部当成产品展开成本或可实现加速比。
原始 trace 留在本地；`cpu-summary.json` 和 `cpu-manifest.json` 保存范围与构建身份。

## 架构决定

保留 Observation／任务生命周期边界和现有 AppKit 正文虚拟化。正文已经不是一个
简单的全量 SwiftUI 列表；换业务状态框架不能直接修复这次几何交接。
下一项架构实验应围绕正文块的首次布局与长输出呈现，分别测量创建、文本布局、
显示提交；再决定是否需要更细的原生文本容器或分块布局。AppKit 视图操作仍留在
主线程，纯内容准备能否后台化须由相应阶段占比支持。TCA 暂无本轮性能采用依据。

本轮不引入预加载、扩大宿主缓存或截掉历史；这些会带来新的内存、选区、搜索和
阅读锚点契约，应作为独立候选比较。

## 验证与边界

候选的前插锚点、缩放、搜索、会话往返、轮次导航、图片检查通过。完整阅读三轮
与小幅滚动三轮通过。逐次状态、源码/夹具/二进制哈希在 `results.json`。
基线与候选的夹具差异仅为 disclosure 失败证据采集；本报告不计算滚动加速比例。
全工作台（两种侧栏）、详情生命周期、Kimi 输入、输入正向控制、生产构建及严格签名、
WorkbenchChecks、ConnectionChecks、滚动跟随、22 项性能工具测试和本地化检查均通过。
生产二进制无实验侧栏/采样探针符号。实 SSH 因未配置 WORKBENCH_LIVE_HOST 跳过；
最终结果见 `validation.json`。

真实 Perch 展开观察最初被自动审批拒绝；用户随后明确授权，已完成只读展开、收起
和往返滚动，见 [真实观察补充](LIVE-OBSERVATION.md)。运行中的构建不是本轮候选，
且采样含明显的辅助功能查询开销，因此不能用这次观察认证候选修复或自然滚动性能。
触控板惯性、硬件 IME、完整长内容按钮和有效显示帧仍未验收。

```sh
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py disclosure --disclosure-context \
  --assert-atomic-disclosure --output .local/disclosure-check
python3 scripts/run-navigation-check.py reading --output .local/reading-check
python3 scripts/run-navigation-check.py scroll --scroll-step-points 8 \
  --output .local/small-scroll-check
python3 scripts/profile-navigation.py disclosure --output .local/disclosure-cpu-check
```

输出目录须为新目录；性能运行与编译/采样串行。未安装、推送或部署。
