# Linux 性能循环基线与可移植修复（2026-11-12）

20x 性能循环的第一轮：让模型层测量循环在 Linux 云机上自动运行并钉死基线。
目标口径为"先盘点再定场景"：对着钉死的 baseline 逐场景评估 ≥20x 余量，
而不是宣称全线 20 倍。macOS 侧盘点（会话切换卡顿、冷启动、帧率、空闲资源）
待 Mac mini 接入后按 [macos-checklist.md](macos-checklist.md) 执行。

## 环境

- Alibaba Cloud Linux 3（glibc 2.32），x86_64，192 核，云主机。
- Swift 6.3.3（amazonlinux2 官方工具链）。6.4 起官方不再提供 AL2 构建，
  其余 6.4 Linux 包要求 glibc ≥2.34，本机 2.32 只有 AL2 路径可用。
- 基线 commit：`82864b0`（origin/main，v0.8.0）+ 本报告随附的可移植修复；下表为 rebase 到该基线后的复测值（首测在 `cde01a4` 上完成，两轮差异在噪声带内）。
- 与 macOS（Swift 6.4.x、Apple silicon）的绝对值不可互比；Linux 数字
  只用于循环内同机、同工具链的相对 A/B。

## 可移植修复

除第 4 条外，macOS 编译路径逐字不变（`#if` 守卫）；第 4 条为语义等价的
平台无关化，由现有 RemoteFileTests 的 `./` 与 `/./` 形态覆盖。

1. **SwiftMath 只在非 Linux 链接**（CoreGraphics/CoreText 依赖）；
   WorkbenchChecks 的数学渲染冒烟检查在 Linux 打印 SKIP
   （`#if canImport(AppKit)`，与既有"平台相关项跳过"口径一致）。
2. **WorkbenchCore 的 Linux 分支**：
   - `FoundationNetworking` 条件导入（KimiAPI、ActivitySummary、
     GroupSuggestions、SessionNaming、TaskRecap）；
     Linux 的 URLSessionWebSocketTask 可用性已验证。
   - CryptoKit → swift-crypto 5.1.1（ReviewContext 指纹；
     `.when(platforms: [.linux])` 条件依赖，macOS 仍用 CryptoKit）。
   - NSDataDetector → RFC 3986 字符集正则 + 尾部标点修剪
     （ReplyDocument 裸 URL 链接化；覆盖检查断言的中文句号截断形态）。
   - Darwin socket 分支（KimiAPI：`sin_len`、`SOCK_STREAM` 类型）。
   - `String.LocalizationValue` shim（LocalizationCompat.swift，仅 Linux
     编译）。checks 二进制不携带 .lproj 资源，macOS 上 `String(localized:)`
     同样回退 key，故 shim 的"key + 插值拼接"与 macOS checks 行为等价。
3. **SetupCommandRunner 超时修复（真实 Linux 缺陷）**：Swift 协作池线程
   阻塞全部信号，posix_spawn 让子进程继承该掩码
   （实测子进程 `SigBlk=fffffffe3bfbea27`），SIGTERM 永远 pending，
   超时形同虚设（`sleep 5` 跑满 5.0s；独立进程对照 0.15s 即终止）。
   修复：Linux 上 spawn 前临时解除本线程信号阻塞、spawn 后恢复；
   `stop()` 改用自管 `launched` 标志调用 `terminate()`（corelibs 的
   `isRunning` 在启动 runloop 之外读数不可靠；子进程未被 wait 前 pid
   不会复用，terminate 安全）。证据：A/B/C 三组探针隔离出
   "spawn 时线程掩码"是唯一变量。
4. **`RemoteFilePath.standardize`**：corelibs 的
   `NSString.standardizingPath` 不消除 `./` 组件（macOS 会消除），导致
   referenceCommand 的证据根后缀匹配失败、回退 cwd，而 shell 的
   `[ -e "$cwd/./rel" ]` 按文件系统遍历读到了过期主副本。把 `resolve`
   已有的纯 Swift 词法归一化提为公共 `standardize`（保留相对路径前导
   `..`，与 macOS standardizingPath 语义一致），`resolve` 与
   `referenceCommand` 共用单一实现。
5. **Bench 计时**：QuartzCore `CACurrentMediaTime` → `benchNow()`
   （BenchClock.swift：Apple 用 CACurrentMediaTime，Linux 用 dispatch
   uptime 单调钟）。

## 检查

- `WorkbenchChecks`（Linux，release）：**84 PASS + 1 SKIP**（数学渲染需
  AppKit），exit 0。
- `check-functional.py portable`：10/10 PASS。

## 模型层基线（3 轮，中位数；轮间噪声 <2%）

`WORKBENCH_BENCH=streaming`（16,142 条消息 / 8,993 entries / 692 行，30 次测量）：

| 指标 | 中位数 |
| --- | --- |
| 每个流式 delta 全链 chain_total | 2.90 ms |
| 　presentation_update（tool_projection 1.58 为大头） | 1.95 ms |
| 查找栏有查询词时 find_bar_query_update | 2.05 ms |
| 向上加载一页 older_page_full_chain | 12.94 ms |
| 释放 16k 会话模型状态 | 12.66 ms |

其余 bench：

| 场景 | 数值（3 轮区间） |
| --- | --- |
| 首访投影 2,333 条（bench 1） | cold 84.1–84.8 ms；append 0.36 ms |
| 首访投影按消息数线性（117→2,333 条：4.3→84.7 ms），16k 条外推 | ≈580 ms 模型层 |
| 编辑统计 6,400 条（activity） | 9.35–9.44 ms |
| token 级 delta 每次更新（presentation-token，199/200 轮复用） | median 0.50 ms，p95 0.82 ms |

## 判断：20x 余量在哪

- 流式每 delta 0.15–0.5 ms、查找期间 2 ms、翻页 12.6 ms：10 月两轮优化后
  已贴近模型层下限，**无 20x 余量**。
- 大会话冷投影 ≈580 ms/16k 条（外推）为**候选**：20x 意味着 ~30 ms，
  需要算法级改变（增量/懒投影），先在 Mac 上确认真机首访占比再立项。
- 明确的 20x 候选在 macOS 侧：切换会话 1.3–1.6 s 未归因卡顿
  （2026-10-24 报告遗留）、冷启动、空闲资源（336/522 MB 历史样本）。
  待 [macos-checklist.md](macos-checklist.md) 数据回来后排序立项。

## 未验证

- macOS 编译、macOS CI 组（数学检查、ConnectionChecks、preview apps、
  native acceptance）：`#if` 分支理论上不影响产品路径，但需 macOS 构建
  确认后再合并。
- `standardize` 与 macOS `standardizingPath` 的等价性仅由现有测试形态
  覆盖，需 macOS CI 的 RemoteFileTests 通过背书。
- 真机（Mac mini）基线全部未测；hitch 校准自 2026-09-23 起未通过，
  帧率类结论前必须先跑 positive control。

## 复现

```sh
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
swift build -c release --product WorkbenchChecks
bin=.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
"$bin"                                  # 完整检查套件
WORKBENCH_BENCH=streaming "$bin"        # 流式/翻页/查找基准
WORKBENCH_BENCH=1 "$bin"                # 首访投影基准
WORKBENCH_BENCH=activity "$bin"         # 活动栏派生基准
WORKBENCH_BENCH=presentation-token "$bin"  # token 级更新基准
```

原始日志：本轮运行产物在测量机 `.local/20x-baseline/`（gitignore，不入库）。
