# 原生行布局候选验收与滚动归因（2026-10-10）

本轮没有得到可以上线的新增提速方案。气泡宽度候选未通过原生布局一致性验收，已移除；重复刷新与热区重复排布的计时不足以解释主要卡顿。保留诊断，并将下一轮范围收窄到行创建、挂载和复杂 SwiftUI 行测量。

## 来源与复现

- 基线：`c9c651f66229bea17078daa7dfbadc454cf4f4b7`（已包含 payload cost 复用，不包含未采纳的行宿主缓存）。
- Qwen 候选：`edefda615aa2e3f8562c57b259a1052ac388de8b`，本地引入为 `58325b2`。
- 5.6 滚动诊断：`0a245bf60e3233ec3cf46c42cccbed57aff1a79e`，本地整合为 `9778c5508dbbe4f24cc1d463848e30c81a064d52`。冲突仅合并诊断 API；次数写入 `render_counters`，不伪造零耗时样本。
- `bubble-*`、`diagnostic-*`：从 `9778c55` 编译；`kind-*`：同一提交加本目录 `measured-kind.patch`，区分原生用户、原生助手和各 SwiftUI presentation。每组诊断顺序运行三次，fixture 为 200 turns、120Hz 请求频率。运行时没有并行构建。
- `raw/*/supervisor.json` 保存编译器、源文件摘要、fixture 摘要、二进制摘要和退出状态。路径统一脱敏为 `<worktree>`。全部为独立验收应用，不是用户另一台电脑上的真实会话。

历史复现（含被否决候选，需在独立 worktree 切到上述测量提交）：

```sh
bash scripts/build-navigation-preview.sh
NAVIGATION_BUBBLE_IDEAL_PROBE=1 python3 scripts/run-navigation-check.py user-rows --output .local/bubble-baseline
NAVIGATION_BUBBLE_IDEAL_PROBE=0 python3 scripts/run-navigation-check.py user-rows --output .local/bubble-candidate
NAVIGATION_BUBBLE_IDEAL_PROBE=1 python3 scripts/run-navigation-check.py fast-scroll --output .local/diagnostic
```

最终代码移除了该开关和候选；默认验收命令不需要环境变量。`summary.json` 是原始阶段计时的三轮中位数与各轮原值。

## 1. 气泡有界宽度探测：否决

原布局通过 `user-rows`；候选失败：`Native user layout differs from SwiftUI: heights [1646.0, 1646.0], drift 49.0`。

失败样本是 340pt 宽度下含中文、emoji、组合重音字符的长段落。候选与 SwiftUI 高度相同，但起始字形 x 为 114pt / 65pt，相差 49pt。原始字形坐标见 `raw/bubble-candidate/native-user-parity.json`。

错误假设是“在最大宽度测得的文字宽度小于上限，就没有换行”。实际已换行的每行也可能短于上限，导致候选错误缩窄气泡。Linux 算术自测不能替代 AppKit/SwiftUI 原生布局对照。未继续对错误布局做性能比较，最终恢复原来的理想宽度探测。

## 2. 重复滚动工作：次数多，但已测部分很便宜

下表单位为 **每个完整阶段累计毫秒的三轮中位数**，不是每帧耗时，也不是 FPS。

| 指标 | 冷滚动 | 全程返回 | 同屏往返 |
|---|---:|---:|---:|
| 相同可见范围的刷新 | 0.421 | 0.317 | 1.454 |
| 原生行 place | 126.909 | 158.413 | 0.399 |
| 行创建 | 218.135 | 242.533 | 0 |
| 原生路径 Markdown 解析 | 69.795 | 65.931 | 0 |
| SwiftUI 路径 Markdown 解析 | 10.368 | 11.839 | 0 |
| 无宽度上限的文字测量 | 19.618 | 18.804 | 0 |

冷滚动有约 1,500 次相同范围刷新，但 guard 快速返回后总成本约 0.4ms。热区 120 次原生 place 的累计成本约 0.4ms。不能仅凭调用次数引入另一层布局缓存，也不应删除保证可见行及时挂载的同步路径。冷/返回的 place 包含首次排布，不能把总值当成重复排布的可节省空间。

原有 `markdown_parse` 没有覆盖原生路径，所以“只有 39 次解析”的结论不完整；补充的 `row_parse` 能覆盖另外 317 / 310 次尝试。

## 3. 修正“助手测量”的归因

旧 `host_measure_assistant` 实际代表所有非用户提示行，包括工具和思考记录，并不等于助手正文。新增指标按实际 renderer/presentation 区分。以下同样是三轮 **完整冷滚动阶段累计毫秒中位数**：

| 行类型 | 数量 | 创建 | loadView | 显式测量 |
|---|---:|---:|---:|---:|
| 原生用户 | 198 | 79.033 | 149.539 | 0.148 |
| 原生助手 | 80 | 179.549 | 3.697 | 2.842 |
| SwiftUI 富文本正文 | 39 | 20.521 | 0.579 | 127.790 |
| SwiftUI 工具活动 | 80 | 11.289 | 1.185 | 68.022 |
| SwiftUI 思考记录 | 40 | 4.364 | 0.441 | 41.589 |
| SwiftUI 空输出 | 40 | 4.493 | 0.505 | 8.354 |

多个指标互有嵌套，不能直接相加得总耗时。原生文字的首次测量还会发生在先于 `measure` 的 `place` 中；因此显式测量很小不代表原生文字排版免费。`loadView` 包括子视图挂载，不能等同于 Swift 对象分配。

全程返回没有显式测量缓存未命中，但仍有行重建和挂载：原生助手创建累计中位数 134.302ms，用户行 loadView 为 185.815ms。只缓存高度不能消掉这些成本。短距离热区没有这些创建/测量计时；其持续滚动卡顿还需要帧呈现证据，不能由当前 CPU 计时宣称解决。

## 下一轮边界

1. 优先细分原生行的创建/挂载：归因文本视图挂载、内容绑定、SwiftUI 复制按钮宿主；在最昂贵的实际子路径做单变量试验，不扩大整行缓存。
2. 对复杂 SwiftUI 正文、工具活动、思考记录分别做固定宽度测量对照。先保持现有交互、选择、复制、无障碍和动态高度，再比较冷滚动/返回的收益。
3. 热区问题单独获取用户目标机器的帧呈现或可重复滚动证据；现有计时不能证明 120Hz。此前 Instruments 帧表无事件的结果也不能证明没有掉帧。

当前证据支持继续处理渲染器边界，不支持为性能直接引入 TCA 或整体重写。

## 验证

- 原布局 user-rows：通过；有界宽度候选：失败，已移除。
- 细分前 3 次、细分后 3 次 fast-scroll：通过。
- `swift run --build-system native -c release WorkbenchChecks`：48 项 PASS；未配置 `WORKBENCH_LIVE_HOST`，真实 SSH 集成检查跳过。
- `bash scripts/build.sh`：Release 构建通过；`codesign --verify --deep --strict build/Perch.app` 通过。编译器存在已有 warning，无构建错误。
- 移除候选后重新构建 Navigation Preview，`user-rows` 与 `fast-scroll` 均通过，见 `raw/final-*`。
- 尚无用户另一台电脑上的真实会话验收或有效帧呈现指标。本轮不声称已消除体感卡顿。修改仅在本地独立实验分支，未推送或部署。
