# 第四轮候选收尾

采用两个局部改动：工具卡每次 body 求值只解析一次退出状态；原生 Markdown 准入失败时把当前 entry 已解析的不可变 blocks 传给 SwiftUI 回退路径。没有引入全局缓存、整行保留或新状态框架。

## 范围与来源

- 基于主线 `1714140`，包含已合入的 PR #103、#104、#105。
- 工具卡候选来自 `e8193cb`，本地为 `55dbd9e`；解析候选来自 `3c9589a`，本地为 `3da769f`。
- 收尾补充生产工具卡原生验收，校正退出报告计数，移除已否决的气泡开关及文档残留。
- 原生逐个 addSubview 候选 `f298f08` 未采用：三轮/臂对照的冷阶段目标挂载中位数 91.000 → 97.021ms，没有稳定整体收益。该候选不在交付代码中。

## 已验证的改进

解析复用限于当前 controller/root；session、message ID 和 source 均匹配才复用。内容替换或会话切换不复用旧准备值，直接 SwiftUI 路径仍正常解析。

同二进制 off/on/on/off/off/on 共六轮、200 turns 的程序化滚动中，冷滚动与全程返回各 39 次 SwiftUI 回退解析降为 0 次（对应各 39 次复用）。六轮没有缺失可见行，文档高度一致。见 `parse-reuse-runs.json`。这些是清理前候选的工作量证据；各轮未保存外部进程快照，因此不据此宣称完整滚动耗时提升。

工具卡计数位于实际退出报告读取处，区分：

- `tool_card_exit_report_read`：属性读取次数，应与 body 求值次数相等。
- `tool_card_exit_report_output_display`：failed 且有 output 时求 display，包含无退出码标记的失败。
- `tool_card_exit_report_json_encode`：上述 output 非字符串时的 JSON 编码；字符串输出不计入。
- `tool_card_exit_report`：实际属性读取的计时，诊断仅编入验收应用。

移除原先人为执行七次/一次属性读取的合成基准：它可以说明重复计算昂贵，但不证明真实 SwiftUI 的求值次数或布局收益。生产工具卡仍保留所有标题、状态、关注颜色、复制、展开及无障碍行为。

## 原生验收

新 `tool-card` 模式实际挂载生产 `KimiToolCard`，已接入 `check-functional.py native`。覆盖 1600 行结构化失败输出（有/无退出码标记）、字符串失败输出、无输出失败、运行中、缺失调用记录；分别在浅色 700pt、深色 340pt 下验证实际无障碍标签和读取/编码计数。另检查展开、同 ID 替换、Unicode 文本复制和重新挂载后的展开状态恢复。

首轮测试的 AX 协议强转没有遍历到 SwiftUI 的虚拟节点；改为读取节点公开的标准 AX selectors。第二轮的复制测试硬编码了剪贴板类型；改为沿用现有正文验收，从 NSTextView 的 writablePasteboardTypes 中选择文本类型。两项修改仅涉及验收代码，未改变生产行为。

最终验证全部通过：

- `tool-card`：12 个状态/外观样本；每个样本实际 body 求值、退出报告读取均为 1 次。两个结构化失败场景各编码 1 次，即使没有退出码标记也正确计数；字符串场景编码 0 次。两种外观下同 ID 替换、复制、展开状态恢复均通过。
- `assistant-rows` 消融关闭/开启均通过：4 个 rejected 样本的回退解析 4 → 0，复用 0 → 4，direct SwiftUI 解析仍为 1 次。
- 最终 `fast-scroll` 通过：cold/revisit 各 39 次复用，实际回退解析为 0，无缺失可见行。
- Release WorkbenchChecks：48 项 PASS；真实 SSH 未配置 live host，保持 SKIP。
- Performance Python 检查：22 项通过；修改的 Python 脚本编译检查通过。
- `scripts/build.sh` 与 `codesign --verify --deep --strict build/Perch.app` 通过。

见 `tool-card.json` 和 `validation.json`。最终原生验收二进制 SHA256 为 `edb6cb7deb95492b9f88fdc707ecc1d2ec9d72122fd7e86419fba8955cff3997`。构建时 HEAD 为收尾提交的父提交 `02cad72`，源文件与 fixture 摘要记录的是当时待提交的最终代码树；随后仅补充本报告和测试记录。

## 证据边界

本轮验证的是重复工作消除和原生行为保持，不是显示帧率、真实触控板延迟或用户另一台机器上的会话。快速来回滚动的整体体感尚不能宣布收尾。修改未部署。

## 复现

```sh
swift run --build-system native -c release WorkbenchChecks
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py tool-card --output .local/tool-card
NAVIGATION_REUSE_REJECTED_MARKDOWN=0 python3 scripts/run-navigation-check.py assistant-rows --output .local/assistant-off
python3 scripts/run-navigation-check.py assistant-rows --output .local/assistant-on
python3 scripts/run-navigation-check.py fast-scroll --output .local/scroll
bash scripts/build.sh
```
