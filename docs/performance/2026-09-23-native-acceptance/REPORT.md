# 正式组件隔离验收与采集校准

本轮落地可重复的原生验收入口、初始基线和性能验收规范。正式搜索的本地化标签计算已取得热点证据；尚未修改这条产品路径。帧数据可以按 Perch 进程关联，但自动 hitch 计数未通过已知停顿校准，不能用“0 hitch”宣称流畅。

## 版本与隔离

- 开始前检查规则、工作树和现有改动；在既有独立任务工作树继续，起始无未提交改动。
- 拉取并重放到 `origin/main f9036b7adbf41e9510be609e2326b308b8f9df1b`，包含新消息气泡尺寸和桥接重启修复。提交前再次 fetch，main 未继续变化且是当前 HEAD 的祖先。
- 测量时父提交为 `3e24df30391775ddb03b957d614c87abf0911437`；新验收代码尚未提交，因此以各 manifest 的源码及二进制 SHA-256 标识实际版本。
- 独立 bundle `dev.perch.nativeacceptance` 使用正式 WorkbenchView、侧栏、搜索弹层、全部会话页和正文组件，编译开关控制入口与探针。使用固定内存 JSON transport，真实解码与选择路径；不恢复保存主机／工作区／草稿，不启动连接，不保存工作区。测试未操作用户真实会话。
- 普通 App 重新构建、签名检查通过；`nm` 确认没有 NativeAcceptance 或 NativeDirectoryProbe 符号。

## 无 profiler 的三次重复

固定 500 个目录项、8 个响应、每会话 200 轮正文、1280×820pt、Release。每次切换 16 次、每种搜索面板 6 个查询、滚动 120 步（80pt 间隔向上后反向），三次功能检查均通过。三个 run 的源码和二进制指纹相同，见 [baseline.json](baseline.json)。

| 测量 | 第 1 次 | 第 2 次 | 第 3 次 |
| --- | ---: | ---: | ---: |
| 切换到布局提交 p95，ms | 199.6 | 181.7 | 224.1 |
| 搜索弹层查询到布局提交 p95，ms | 109.3 | 115.2 | 110.8 |
| 全部会话页查询到布局提交 p95，ms | 174.2 | 187.3 | 172.3 |
| 滚动步到布局提交 p95，ms | 24.6 | 20.4 | 22.3 |
| 滚动步最大值，ms | 54.5 | 54.8 | 50.5 |
| 最大 mounted / retained | 5 / 17 | 5 / 17 | 5 / 17 |
| RSS 开始 → 结束 → 静置 2 秒，MiB | 148.0 → 187.7 → 187.7 | 147.9 → 186.9 → 186.9 | 148.2 → 187.2 → 187.2 |

计时终点包含 layout/display/CA flush，**没有测量硬件输入到屏幕呈现**。切换包括实际 JSON 解码，并非旧预览的缓存命中测试。p95 使用排序后 `floor((n-1)*0.95)` 索引；查询仅 6 个样本，数值用于探索，不报告稳定 p99。RSS 增加约 39MiB 且短暂静置未回落，当前证据既不能诊断泄漏，也不能证明长期资源有界。

机器是 M3 Pro / 18GB / macOS 26.6.2，Swift 6.4；配置快照见 [environment.json](environment.json)。固定内容、窗口及构建方式，但未锁定刷新率、温度或后台负载。这是探索性 A/A 基线，还不是可跨机器比较的发布成绩。后续 A/B 应在负载稳定时交替测量。

## CPU 归因

[cpu-baseline.json](cpu-baseline.json) 为较早一次 fixture 构建，使用 Time Profiler + Points of Interest。与最终 fixture 的差异为会话正文挂载就绪判据、可选停顿注入；正式产品组件一致，不能把两版时序差异当优化收益。

仅统计 DirectoryQuery signpost 区间内的主线程样本：12 个区间合计 1314ms。`WorkspaceSession.matchesSearch` inclusive 为 782ms，`SessionKind.label` 为 670ms，`AppLanguage.resolvedLocale` 为 445ms。采样栈支持正式目录筛选反复进入标签／本地化解析这一热点；它们彼此包含，不能求和或直接推算收益。探针不会额外筛选目录，预期选择校验在计时区间外执行。

下一次最直接的产品实验是减少这一已确认路径的重复计算，同时保留语言切换、Agent 名称和目录搜索语义，再用此入口进行交替 A/B。正文首次挂载／测量仍需独立拆分，不据本次搜索数据宣称其已解决。

## 帧采集与失败校准

- [frame-baseline.json](frame-baseline.json)：HistoryScroll 约 3.02 秒，126 条目标进程 update，按 display / swap-id / surface-id 关联到 125 个帧生命周期，未关联 update 为 0。生命周期 p95 28.99ms 是管线区间，不是刷新间隔或 FPS。
- [frame-positive-control.json](frame-positive-control.json)：在第 40 步明确阻塞主线程 120ms。取得 148 条 update、147 个关联生命周期；覆盖该停顿的生命周期结束时间间隔约 166.67ms。**app hitch 仍为 0，因此校准失败，supervisor 返回失败。** 录制本身 exit 0 与功能回放通过均不能覆盖此失败。
- [parser-negative.json](parser-negative.json)：保留全局帧事件但清空目标 update 表，解析器正确返回 unverified / exit 1。这回答了“错误归属或空测量会不会被当作 0 卡顿通过”。

目前确认可取得属于本 App 的帧事件；尚未确认该 Instruments 模板／导出表为何漏报已知停顿。保留 trace 及失败结果，后续需在 Instruments 时间线上核对该区间的 hitch 分类与呈现语义。普通 frames 命令成功只代表采集可用，不能作为流畅发布门禁。

## 功能与构建证据

- 三次自动回放：目标会话 snapshot 与其正文行已挂载、搜索首选项及无匹配状态正确、保留宿主数量检查通过。
- Mac 界面操作：正式搜索输入 `0002`，回车后标题显示会话 0002；输入无匹配词显示“没有找到会话”；全选清空、Down、Return 后打开会话 0001。截图观察到正文、表格、代码和输入框正常展示。这是行为验证，不使用自动化工具往返耗时衡量响应速度。
- `scripts/build.sh`、普通 App 深度严格签名检查、Release WorkbenchChecks 全部通过。只读 SSH 检查因未设置 WORKBENCH_LIVE_HOST 跳过。详见 [production-checks.json](production-checks.json)。
- Python 编译检查、Shell 语法检查、diff 空白检查通过。

尚未完成：全历史消息覆盖、锚点／折叠状态的整套回归、图片加载、硬件触控板惯性、中文输入法组字、流式更新并发、真实远端和 30–60 分钟资源趋势。本轮入口只增加正式组件的短回放，不取代现有混合历史与锚点验收，不宣称 APP 卡顿已经解决。

## 复现与失败保留

执行入口、采集边界与验收门槛见 [NATIVE-PERFORMANCE.md](../NATIVE-PERFORMANCE.md)。原始证据留在本工作树 `.local/native-acceptance/`：`final-1` 至 `final-3`、`cpu-baseline`、`frame-baseline`、`frame-positive-control`、`parser-negative`；大型 trace 不纳入 Git。

开发期间的 Swift 浮点字面量编译失败和重复打包 Ghostty 只读资源失败分别保留在 `build.log`、`build-3.log`；已修正字面量和自有验收 App 的重新打包路径，后续构建通过。早期三秒采集能力探测保留在 `frame-probe-initial`，它不是功能或性能通过证据。正向校准失败原样保留，未调整规则将它改判成功。

本轮仅本地提交；未推送、合并、发布或操作其他任务。
