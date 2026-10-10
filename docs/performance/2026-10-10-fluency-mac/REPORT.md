# Mac 接手验收：正文滚动与 token 更新

## 决定

采用两项局部修复：无行号后缀的文本跳过文件引用正则；未改变消息复用缓存占用统计。
不默认启用行视图保留。它改善短距离反向滚动，却使首次遍历和全历史返回变慢，并增加 RSS。
暂不迁移 TCA，也不把完整历史的状态流一次改成新的协议。

## 来源与范围

- Mac 主线基线 `a1962da`，包含最近的滚动分页和 Kimi heartbeat 修复。
- Kimi 渲染候选 `d7f9645`、汇总工具 `a4e16d7`；状态探针 `ed45714`、`851cd31`。
- 本机实验分支 `codex/fluency-mac-acceptance`：探针移植为 `4cddfc4`/`5ac329c`，渲染候选为 `5504f2c`/`56694b8`。
- 行缓存构建还包含本机修正（随后提交 `71a0d04`）：epoch 独立失效，预算计入工具 input/output/progress 与消息 JSON，增加对应挂载契约。
- token 优化在实验分支为 `500e704`，交付分支等价提交 `8e555bc`。交付分支 `fix/transcript-update-cost` 不包含行视图缓存候选。
- macOS 27.0.1 (26A434)，arm64，Apple Swift 6.4，Release。所有时间都是应用/纯计算夹具耗时，不是显示帧率、硬件输入延迟或真实远端会话验收。

## token 更新：采用统计复用

固定 200/2000 轮，实际 800/8000 条消息；连续替换同一尾消息，5 次预热后记录 30 次。
每个版本运行三轮，表中为三轮各自中位数的中位数。原始样本在 `token-runs.json`。
两个版本都复用 199/1999 轮、仅重建一轮。阶段计时互不重叠，但全部仍是同步 presentation 路径。

| 实际消息数 | 原投影总时间 | 修复后 | 变化 |
| --- | ---: | ---: | ---: |
| 800 | 0.984ms | 0.847ms | -13.9% |
| 8000 | 8.656ms | 7.155ms | -17.3% |

8000 条消息的占用统计阶段由约 1.97ms 降至约 0.44ms。
仍按顺序比较完整消息值，并对变化项重算；不是仅比较 ID。
新增一个与历史等长的 Int 数组，8000 项元素约 64KB（不含数组元数据；不是 RSS 实测）。
历史前插/重排可以退回多项重算，不引入新的事件协议或消息所有者。
工具输出同 ID 编辑、Unicode、前插、截断、清空恢复、epoch/语言变化均与新建 model 的完整占用计算比较。
现有完整投影、live tool handoff、缓存准入与会话隔离契约继续执行。

这只降低流式投影成本；工具归一化、轮分组和行映射仍随历史增长。
没有新消息的滚动不走这条更新路径，因此不能将上述收益称为整体滚动提升。

## 行视图保留：不采用默认开启

同一 Navigation Preview 二进制，按 off/on/on/off/off/on 串行运行六次。
每次 200 轮混合历史、120Hz 程序化滚动。两个配置为容量 0 和容量 48、源载荷预算 1024KiB。
所有运行的源码、夹具和二进制 SHA256 相同；每次启动前未发现 Swift 编译或其他验收/采样进程。
`row-cache-runs.json` 保存完整结果与监督回执（本机输出目录已替换为 `<worktree>`），`row-cache-summary.txt` 为汇总。

| 场景 | 关闭：每步中位数 | 开启：每步中位数 | 判断 |
| --- | ---: | ---: | --- |
| 首次扫读 | 12.28ms | 12.94ms | +5.4%，变慢 |
| 全历史回读 | 11.58ms | 12.51ms | +8.0%，变慢 |
| 同屏小范围往返 | 2.73ms | 1.77ms | 有收益，但两臂均不新建行 |
| 十二屏内反向往返 | 9.51ms | 4.76ms | 约 -50%，局部收益明显 |

全历史回读仅命中 48 行，创建数 466→418；短距离反向 144 次均命中，创建数 144→0。
回读后的 RSS 中位数 166.92→185.83MB，增加约 18.9MB。
这支持“有界缓存只覆盖近期路径”，不支持把保留全历史的收益套用到有限缓存。
汇总脚本的 PASS 只代表某个预测成立，不是上线判断；其 10% 首扫退化阈值不构成产品验收标准。

## 功能检查

- Release WorkbenchChecks：候选与交付分支均执行；真实 SSH 集成保持默认 SKIP。
- 导航夹具（容量 48）：interactions、search、disclosure、anchor、assistant-rows 全通过。
- 完整离线工作台：cache-all、default-all、detail-lifecycle、kimi-refresh 全通过。
- 挂载检查包含 epoch 相同结构时清缓存、超预算工具输出拒绝、同 ID 编辑、外观、前插与删除。
- 功能批次部分与编译重叠，其耗时不进入性能对比。简要结果见 `functional-results.json`。
- 功能通过不代表真实机器触控板体验、可访问性全覆盖或 compositor 帧验收。

## 复现

```sh
swift run --build-system native -c release WorkbenchChecks
WORKBENCH_BENCH=presentation-token .build/release/WorkbenchChecks > token.json
```

行缓存仅在实验分支提供：

```sh
bash scripts/build-navigation-preview.sh
NAVIGATION_ROW_CACHE=0 python3 scripts/run-navigation-check.py fast-scroll --output .local/off
NAVIGATION_ROW_CACHE=48 python3 scripts/run-navigation-check.py fast-scroll --output .local/on
```

后续优先在真实卡顿机器上验证已交付小修复；继续处理长历史的工具/行投影线性成本，
并修复显示帧测量正对照。没有这些证据，不能宣称正文流畅度已经收尾。
