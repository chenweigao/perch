# 会话切换的初始正文稳定性

修复 Kimi 已缓存会话切换时先显示正文开头、随后跳到末尾的问题。
基线夹具中三次缓存切换都先暴露第 1–2 轮，16.9–19.4ms 后才到第 199–200 轮。
这是一条可复现的闪烁来源，不代表已经穷尽真实会话的所有闪烁原因。

## 改动

- Kimi 工作区按连接保持身份，缓存命中切换复用滚动容器和文档宿主。
  会话草稿、提问答案和子任务弹层仍按会话隔离或重置；回看动作计数保持单调，
  切换不会触发一次额外的回看动作。
- 生产正文在初始高度与阅读位置就绪前隐藏：跟随末尾时直接测量尾部，
  关闭跟随时等待阅读锚点恢复。准备期间不覆盖已保存的锚点。
- 正文实际高度、实际可见区域及待恢复状态共同决定显示时机，没有定时延迟。
  显式滚动/导航可以取消等待。Kimi 与 Native 使用同一机制；从顶部开始的独立
  预览不启用该机制。远端连接生命周期没有改动。

## 隔离回归

`kimi-switching` 使用真实工作台和本地 Kimi 协议夹具，每个会话 200 轮。
每次切换在主线程让出后刷新布局，约每 8ms 采样，共 60 次；实际间隔受布局工作影响。
基线与候选都有源代码及二进制指纹，记录见 `results.json`。
基线是加入诊断后的旧行为；候选的断言另覆盖连续切换、容器复用及阅读锚点。

| 场景 | 基线 | 候选 |
| --- | --- | --- |
| 三次缓存切换 | 每次先显示第 1–2 轮 | 首次可见即为尾部 |
| 缓存切换的滚动容器/文档 | 重建 | 复用 |
| 冷加载 | 经过加载占位 | 经过加载占位后显示尾部 |
| 离开第 81 轮再返回 | 本轮基线未测此项 | 首次可见即为原条目及 0pt 偏移 |

候选六次切换的可见布局样本均通过断言：没有旧会话正文；跟随状态直接在末尾，
返回中途阅读会话时锚点和偏移一致。夹具末尾距滚动容器底部 12pt 是既有内边距。
采样不能排除两个样本间的短暂状态，不是显示帧率、触控板惯性或硬件输入延迟证明。
单次切换耗时也不作为性能提升结论。

已验证 `detail-lifecycle`、`kimi-invalidation`、`paging`、导航 `reading`、
`interactions`、`anchor`，并通过 22 项性能工具测试。覆盖加载失败/重试、
输入撤销与草稿隔离、历史前插、展开、返回会话与宽度变化等已有契约。
新切换回归已加入 macOS functional checks。

## 复现

```sh
bash scripts/build-native-acceptance.sh
python3 scripts/run-native-acceptance.py --mode kimi-switching --output .local/switch-check
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py reading --output .local/switch-reading
python3 scripts/run-navigation-check.py interactions --output .local/switch-interactions
python3 scripts/run-navigation-check.py anchor --output .local/switch-anchor
```

结果目录必须是新目录。原始布局采样保留于本地 `.local/switch-flicker/`；
提交的 JSON 只保留发生变化的样本、原始报告指纹和运行出处，移除本机仓库绝对路径。
