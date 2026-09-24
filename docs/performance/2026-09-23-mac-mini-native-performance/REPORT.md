# Mac mini 原生搜索性能复核

## 范围与环境

执行主机 本地验收 Mac：Mac mini M4、16 GB、macOS 26.3.2、Apple Swift 6.3.3。基线为现场 fetch 后的 origin/main 9c1e632596281cc83814ca3683f5ac9bb0427f36；独立工作树为 <workspace>/_worktrees/mac-mini-native-performance/perch，分支 codex/mac-mini-native-performance。原 mac-mini-build 工作树未修改。

当前用户有 Aqua 登录会话；NSScreen 返回一个在线、唤醒、1920×1080 的屏幕，固定验收窗口为 1280×820pt。未确认屏幕为实体显示器，也未测硬件键盘、触控板或输入法到呈现的延迟。曾启动隔离 App 尝试手动键盘打开，但本机 Computer Use 的辅助功能与录屏权限未授予，故该路径未实测；App 已停止。只有 Command Line Tools，没有完整 Xcode；xcrun 无法找到 xctrace，故本机没有 DirectoryQuery 的 Time Profiler/Points of Interest trace，也没有可用的 Instruments 帧验收。旧报告中 120ms 注入停顿仍被 app hitch 表报为 0 的正向校准失败未解决，不能把 0 hitch、布局提交或 CA flush 当成 FPS。

固定离线 fixture：500 个目录会话、8 个本地 JSON 快照、每快照 200 轮、Release，正式 WorkbenchView/SessionDirectoryView/正文组件，真实本地 JSON 解码和选择路径。无远端连接，不接触用户保存的会话。每次无 profiler 回放执行 16 次会话切换、搜索弹层和全部会话页各 6 个查询、120 个滚动步。查询计时从 fixture publisher 写入本地 query 到布局/display/CA flush，不包含硬件输入投递。每次 6 个查询的 p95 仅是探索值，不报告稳定 p99。

## 问题 1：Swift 6.3 构建阻碍

未修改的最新 main 在本机无法构建原生验收 App。ActivitySummaryBatch.init 对两个静态方法缺少 Self. 限定；修正后 NativeAcceptanceFixture 的 500 项 map 表达式超过 Swift 6.3 类型检查预算。仅限定静态调用并拆出 reference/title 局部量，不改变摘要行为或 fixture 内容。失败日志保留在 .local/native-performance/build-baseline.log 与 build-baseline-compat.log。随后同一验收脚本、普通 scripts/build.sh、WorkbenchChecks 均通过；兼容修复已单独本地提交 33de79b。

## 问题 2：搜索反复解析无关的本地化标签

实际路径是 SessionDirectoryView 的本地 query 状态过滤 model.allSessions，逐项调用 WorkspaceSession.matchesSearch，再读取 reference.kind.label。旧实现每次构造整张字典，构造时即求值终端条目的 L("终端")；因此 fixture 中的 OMP 会话也进入 AppLanguage.resolvedLocale。此前 MacBook 的 DirectoryQuery 主线程采样中，12 个区间累计 1314ms，matchesSearch inclusive 782ms、label 670ms、resolvedLocale 445ms；三者互相包含，不相加，也不据此推算收益。Mac mini 无法重新取得同类 CPU trace；代码路径与本机 A/B 查询耗时共同支持该原因。

最小修复是把 SessionKind.label 改为 switch：非终端 Agent 返回原来的常量，只有 terminal 调用原有 L("终端")，所以终端仍按当前语言动态本地化。标题、Agent 名称、目录、环境和详情组成的搜索文本与分词/匹配规则不变；空查询、无结果、键盘选择及打开逻辑未改。

## 本机测量

改动前先做 3 次同源码、同二进制的 A/A 无 profiler 回放，三次功能检查通过。搜索弹层查询到布局提交 p95 为 64.6/62.6/63.3ms，全部会话页为 59.7/64.7/73.7ms；滚动步 p95 为 19.9/20.3/22.7ms。A/A 与后续 A/B 的源码指纹相同，但基线二进制经过重新构建，勿将两组混作一个固定二进制实验。

随后保存两个 Release App，按 A1-B1-A2-B2-A3-B3-B4-A4-B5-A5 交替运行；A 是兼容修复后的基线，B 是标签 switch 候选。两者分别固定同一个二进制与源码指纹，运行同机、同 fixture、同窗口，10 次行为检查均通过。完整各轮指标、指纹及顺序见 measurements.json。

| 每轮 p95，ms | A 范围 / 中位数 | B 范围 / 中位数 |
| --- | ---: | ---: |
| 搜索弹层查询到布局提交 | 63.8–91.9 / 64.9 | 24.6–29.2 / 24.9 |
| 全部会话页查询到布局提交 | 64.5–106.7 / 67.5 | 23.5–32.3 / 31.3 |
| 会话切换到布局提交 | 65.8–75.3 / 70.2 | 65.8–78.8 / 77.4 |
| 滚动步到布局提交 | 19.0–21.0 / 20.0 | 19.2–21.0 / 19.8 |

前三组 A→B 中，B 的会话切换 p95 分别高 9.63、7.41、6.30ms（约 6.3–9.6ms）；两组 B→A 中双方分别约 65.8ms 和 75.3ms，中位数也接近。现有证据未确定这是候选回归还是顺序/环境波动，不将切换改善或无回归写成定论。搜索查询改善在五组中保持。所有运行最大 mounted/retained 为 5/17；静置 RSS A 为 181.0–184.1MiB、B 为 177.3–187.9MiB，短测不能推断长期内存趋势。

## 语义与构建验证

候选 WorkbenchChecks 全部通过。Navigation Preview 的 reading、anchor、search、roundtrip、turns、interactions 六项均通过：200/200 轮可见，540 条消息前插 20 条后锚点保持，20 个往返周期丢键 0，搜索无失败项，流式锚点、空会话及会话切换检查通过。普通 Perch.app Release 构建和严格签名检查通过，生产二进制未包含 NativeAcceptance/NativeDirectoryProbe 符号。未隐藏历史、丢消息或关闭功能。

原始每轮 result/manifest、构建失败日志及构建产物留在此工作树 .local/native-performance；只将小型汇总证据纳入 Git。未采集 trace。没有推送、合并、发布或操作其他任务。

## 仍需验证

最值得先做的是在安装完整 Xcode、确认目标显示器与刷新率后，以本机同一 fixture 采集短 DirectoryQuery CPU trace，核对 resolvedLocale 栈是否消失，并排查会话切换 p95 的顺序效应。帧流畅度验收须先解释并修复已知停顿的 hitch 正向校准，再进行真实键盘/IME、触控板惯性和长时资源观察；当前布局提交与滚动步耗时不能代替这些结论。
