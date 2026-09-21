> 本轮最新记录：[PERFORMANCE-VIEWPORT-PROBE.md](PERFORMANCE-VIEWPORT-PROBE.md)。200 轮历史重建显著加快，但最终短测仍有尖峰，验收未全部通过；按用户要求收尾，未启动新长跑。

# 200 轮导航短测：尚未通过

2026-09-21。基于 `8b5f9d8`，仅处理 200 轮切换与滚动，不加功能。
**没有启动长跑；200 轮切换仍有秒级停顿，不能作为 Goal A 完成验收。** 正文流式 3× 和旧长跑缺报告问题本轮均未验收。

## 先修正测量口径

接手时 `Tests/NavigationPreview/App.swift`、`History.swift` 已有未提交修改，完整保留：
每个会话使用不同消息 ID；内容标记绑定会话 token；缓存限制为 8；缓存未命中直接失败。
原有报告中不同会话共享消息 ID、仅等待消息数量的切换数据，不能证明真正跨会话重建的延迟。
本轮只再增加 `NAVIGATION_SWITCHES`，默认仍为 40，短探针使用 4。
原始继承补丁保存在本机 `.local/takeover/inherited-navigation.patch`。

## 调用采样与单点实验

500 个合成会话、8 个预解码缓存、200 轮混合历史；中文、表格、代码、工具、思考及无最终文字轮次保持不变。
先运行短场景采样，随后性能对照不带采样器，计时不与编译重叠。

- 切换主线程采样主要处于 SwiftUI 事务和布局。可归属应用代码的主要热点是 `ConversationEntryController.measure` → `NSHostingController.sizeThatFits` → 文本/子视图测量；约 1,398 / 6,239 个主线程样本经过该入口。Markdown 解析占比较小。
- 滚动样本中出现 `ConversationEntryContainer.setFrameSize`、可见性切换、约束启停和 AppKit 布局路径。它们的栈存在嵌套，不能将累加样本数当成互斥耗时占比。
- **保留的小改动**：每行已有确定的 frame，其唯一宿主子视图用 AppKit autoresizing 填满行；进出视口不再启停四条 Auto Layout 约束。消息投影、历史内容、行身份、折叠状态和 eager 列表不变。
- **撤回的候选**：直接去掉每行隔离宿主，短切换 60 秒仍未完成，终止实验，随后滚动探针也停止。该候选没有有效耗时报告，未采用。
- 曾考虑惰性列表，但复查已有 `LazyLayoutCacheItem.AllItemsPhaseMutation` 卡死记录后，未拿它作为交付实现。

原始调用栈只保存在本机 `.local/takeover/before/click.sample.txt`、`probe/scroll.sample.txt`、`inline/click.sample.txt`；未提交包含本机环境信息的完整系统采样。

## 无采样器短测结果

| 指标 | 修改前 | 改动后，第 1 次 | 改动后，第 2 次 |
| --- | ---: | ---: | ---: |
| 4 次切换中位耗时 | 4,297.04 ms | 4,230.97 ms | 未重复 |
| 4 次切换最大耗时 | 4,693.94 ms | 4,503.74 ms | 未重复 |
| 240 步滚动中位耗时 | 20.71 ms | 17.69 ms | 17.13 ms |
| 滚动 p95 | 56.89 ms | 47.04 ms | 46.50 ms |
| 滚动最大耗时 | 62.02 ms | 53.65 ms | 51.81 ms |
| 滚动 >16.7 ms 步数 | 123/240 | 124/240 | 121/240 |
| 文档 / 视口高度 | 100,345 / 600 pt | 相同 | 相同 |

滚动 p95 降低约 17%–18%，但过帧预算的次数几乎未变，**不等于滚动已经流畅**。
切换没有明确改善，仍需约 4.2 秒；4 个样本只用于快速判别，不能作为可靠的 p95 验收。
同样不把首次带采样器的测量算入前后对照。

这些数据仅测程序化选择/滚动 → 布局、display、transaction flush；不含实际鼠标事件、网络、JSON 解码和 GPU 呈现。没有据此宣称全 App 提速或卡死已经修复。

原始有效 JSON 与源码哈希：`docs/performance/2026-09-21-navigation-short-probe/`。

## 无报告的独立异常

尝试从 `.local/takeover/*.app` 运行复制的 A/B 产物时，进程均以 `-9` 退出且无报告；系统日志出现 AMFI ad-hoc 签名信任错误，静态 `codesign --verify` 通过。该批次全部作废。
回到标准 `build/Navigation Preview.app` 构建入口后，两侧短测正常结束并生成报告；未修改系统安全设置。
这不是旧 21 分钟退出原因的证据，也未把缺报告视为通过或记成零耗时。

## 下一步与长跑门槛

继续围绕整份 200 轮历史同步构建/测量的成本定位；仅减轻滚动约束不能解决切换。
每次只改变一个机制，先对同一份短场景对照，并检查内容、展开和滚动位置正确性。
**切换仍有秒级停顿时不跑 20 分钟长测。** 达到短测目标且无内容回归后才重新安排长跑。
正式 App、远端 Agent 和 Herdr 会话均未参与测试，B 分支未修改。

## 本次回归

`swift build -c release -j 2 --disable-automatic-resolution` 与 `WorkbenchChecks` 通过，`git diff --check` 通过。
SSH 检查因未设置 `WORKBENCH_LIVE_HOST` 明确跳过。未部署正式 App，未将构建或核心协议检查冒充交互验收。
Navigation Preview 已重新构建回保留的 frame 布局版本；原始未提交修改包含在本地提交中，备份补丁仍保留。
