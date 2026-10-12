# 原生用户消息直接承载行视图

## 结论

采纳一项小范围的视图层级优化：新建的原生用户消息直接作为 controller 的行视图，省去将已填充文本再次挂到空行容器的步骤。助手消息、复杂 Markdown 的 SwiftUI 路径和缓存容量沿用现有实现。

六次同二进制、交替对照中，整段返回滚动的单步 P95 从 17.35–19.03 ms 降到 14.85–14.94 ms。三次各自 P95 的均值下降约 19%。首次滚动收益较小，局部来回滑动没有一致收益；不能据此宣布真实会话滚动问题已经解决。

## 改动与行为

- 保留现有正文文档、可见区和行 controller 生命周期，不增加整行缓存。
- 原生用户视图直接拥有文档中的行 frame，不再把其原点重置为子视图坐标；正文宽度变化仍触发原有高度更新。
- 同 ID 的普通文本更新保持 native view 和选区；只有内容转入另一种 renderer 时才在原位置补回通用容器。
- 回收用户视图时清除行标识和宽度回调，防止复用携带旧行身份。
- `NAVIGATION_DIRECT_USER_ROOT=0` 仅在 `TRANSCRIPT_CHECKS` 编译中用于关闭优化；正式应用直接启用。

这延续了[上一轮的挂载/排版归因](../2026-10-12-skill-scroll/REPORT.md)，但不是再次调整助手 block 的填充顺序。上一轮那个候选只是把耗时移动到后面的阶段，已经撤销。

## 可复核对照

- 基线 commit：`c2d330e5eeed8456f57e6db6cb385da6b2f81879`。
- 本工作树的生产修改和测试修改见 Git diff；源文件、fixture 与二进制摘要包含在 `runs.json` 每次的 supervisor 中。六次二进制完全相同。
- Release：`bash scripts/build-navigation-preview.sh`；macOS 27.0.1 (26A434)，Apple Swift 6.4，arm64。本机独立验收应用，500 sessions / 200 turns 的混合正文。
- 顺序 off/on/on/off/off/on，各次重新启动；显式环境变量 `NAVIGATION_DIRECT_USER_ROOT=0/1`。运行 `python3 scripts/run-navigation-check.py fast-scroll --output <独立目录>`。
- 请求 120 Hz 程序化滚动，实际显示器刷新率未记录。单步包含布局、绘制和事务提交，不包括硬件输入及 compositor presentation；不是 FPS。
- 测量期间未运行本任务的构建或采样器，不保证其他系统负载恒定。仅三个样本/臂，报告范围而不声称统计显著性。

| 场景 | 关闭：中位数范围 | 开启：中位数范围 | 关闭：P95 范围 | 开启：P95 范围 |
| --- | ---: | ---: | ---: | ---: |
| 首次向下 | 11.27–12.81 ms | 10.78–11.30 ms | 18.00–19.61 ms | 16.27–18.13 ms |
| 整段返回 | 11.50–12.71 ms | 11.32–11.43 ms | 17.35–19.03 ms | 14.85–14.94 ms |
| 局部往返 | 2.16–2.77 ms | 2.37–2.85 ms | 5.07–6.29 ms | 5.48–5.64 ms |

返回阶段最大单步：关闭 23.38–24.47 ms，开启 15.49–15.67 ms。返回阶段正文 range 刷新累计：关闭 673–735 ms，开启 541–578 ms；用户行 view 获取累计：关闭 178–207 ms，开启 5.66–5.71 ms。阶段总工作减少，收益不只是某一个计时区间缩短。

返回阶段 RSS：关闭 165.8–166.5 MiB，开启 165.9–166.1 MiB。所有运行无缺失可见行，最终文档高度 96025 pt。保留原始单步样本、阶段指标与构建来源于 `runs.json`；日志位于本机 `.local/direct-user-root/`。

## 功能验证

独立原生窗口检查结果见 `native-checks.json`：

- `user-rows`：已有宽/窄、浅/深色字形位置、Unicode 选择/复制及链接验证；新增真实 ConversationTranscript 中的多行不重叠、append 选区与文本身份、缩放/深色、替换清除旧选区、原生→SwiftUI→原生、用户→助手、切换会话内容隔离。
- `assistant-rows`：已有原生与 fallback 内容、选择、富文本和交互回归。
- `anchor`：历史前插后的阅读锚点。
- `roundtrip`：40 次会话切换回归。
- 六次 `fast-scroll` 全部通过。

生产 Release 构建、核心检查和签名结果在 `validation.json` 中记录。

## Skill 安装

本机新增 Axiom macOS、Axiom Performance（CharlesWiltgen/Axiom）和 Swift Concurrency（AvdLee/Swift-Concurrency-Agent-Skill），均通过 skill-creator 格式校验。继续使用已安装的 SwiftUI Expert 和 Perch 专用性能技能；未安装重复覆盖的 SwiftUI 全套技能。

本轮采用这些技能中的测量、AppKit 桥接和生命周期检查方法，没有引入新的架构依赖。它们的通用建议仍须以 Perch 实测为准。

## 仍未验收

没有部署到用户另一台电脑，没有真实触控板验收，也没有新增有效的 app-owned 帧数据。长助手回复、复杂 SwiftUI 行和首次排版仍是后续候选；本轮只保留已经通过同机对照的一项用户行优化。下一步应先体验本改动，再按真实仍卡的内容形态决定是否继续深入助手行生命周期。
