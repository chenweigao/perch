# 完成态纯散文助手行原生渲染（2026-10-09）

## 本轮交付

完成的 `.message` 助手消息、仅含非空段落的单个 text part 时，改用有界的原生
TextKit 行：与用户散文行共享 `NativeParagraphContent` 准入、字体、链接路由与
选择行为，并带一个以 Markdown 源为身份的小型托管复制按钮。流式输出、活动摘要、
压缩摘要、运行上下文、附件、复杂 Markdown 和 RTL 布局保留原 SwiftUI 渲染器与
外层行身份。行池上限 16，每条回收行最多保留八个已清空文本容器。

## 功能验证

- `assistant-rows` 新夹具：16 组真实排版对照（700/340pt 列宽 × 深浅色），行高与
  所选 glyph 位置差均为 0；链接属性、`perch-file` 路由与跨段 Unicode 复制通过。
- 生产生命周期契约：追加保留行身份与选区；替换清空选区；流式进行时不进入原生
  路径、完成后恢复原行身份；复杂 Markdown 与压缩摘要/运行上下文不进入原生路径；
  复制按钮复制完整 Markdown 源并渲染反馈；回收池不超上限且清空私有状态。
- `interactions`、`WorkbenchChecks` 通过；live SSH 检查未配置，跳过。

## 固定二进制 A/B（同一二进制，`NAVIGATION_NATIVE_ASSISTANT_ROWS=0/1`）

200 轮混合正文，顺序 a1–b1–b2–a2–a3–b3，测量期间无并行编译。数值为每轮主线程
单步布局/绘制处理时间的中位数/p95（ms），完整数据见 `results.json`。

| 场景 | A（原渲染器）median/p95 | B（原生助手行）median/p95 |
| --- | --- | --- |
| 首次整段扫读 | 9.63–10.24 / 16.18–16.59 | 9.85–9.97 / 15.40–16.88 |
| 已读历史返回 | 8.78–9.01 / 14.90–16.11 | 8.52–8.67 / 14.81–15.71 |
| 同屏小范围往返 | 4.20–4.48 / 9.77–10.04 | 4.33–4.60 / 9.69–10.60 |
| 完整下读（reading） | 7.22–7.60 / 13.18–13.69 | 7.25–7.27 / 13.09–13.58 |

整体为**中性**：两臂差异均在轮间噪声内。原因在覆盖面——夹具 279 条助手行中仅
79 条（约 28%）满足纯散文准入，其余含代码/标题等复杂结构仍在原渲染器。微观上
原生路径消掉了这些行的 SwiftUI 图构建：`markdown_parse` 235 → 156 次（-34%），
`host_measure` 374.7 → 320.2ms（-15%）。真实会话中散文回复占比越高，收益越大；
代码重的会话收益有限。这里不声称整体滚动性能改善。

此前一组 A/B 运行（fast-scroll b3、reading b1/b2）与一次并行 release 构建重叠，
数据作废；上表全部来自无干扰重跑。

## 复现

```sh
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py assistant-rows --output .local/assistant-rows
python3 scripts/run-navigation-check.py interactions --output .local/interactions
```

A/B 使用固定二进制与环境开关，原始运行位于本机 `.local/ab-rerun/`。

## 边界

- 准入之外的助手内容（代码块、表格、标题、附件、流式）开销不变，这是当前滚动
  成本的主要剩余部分。
- 夹具不能证明真实触控板体验；正式安装包与开发候选需分别核对版本。
- 未验证 VoiceOver：夹具无法通过进程内树检查获取 SwiftUI 无障碍子项。
