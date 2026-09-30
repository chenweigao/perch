# 连续正文段落合并实验

**保留有界段落合并。** 200 轮混合正文的完整下读/上读固定二进制对照出现稳定改善，
收益主要在首次进入新内容的尾部耗时。本轮不引入 TCA、不改变会话虚拟化或远端连接。

## 实现

连续普通段落共享一个原生 `ReplyTextView`，每组最多八段。标题、代码块、表格、列表项
和引用的结构边界保持独立；列表/引用内部仍使用紧凑段间距。空替代文本等空段落也形成
边界。每组 ID 使用首段的原始 block 下标，流式追加只更新最后一组，已完成组保持相等。

段间距交给原生 paragraph style（正文 12pt、紧凑布局 8pt）；硬换行不增加段间距。
换行继承原字体度量，避免仅含行内代码的段落混入不同字号。链接与文件引用仍走原来的
富文本和点击路由。合并初版发现追加会丢失选区，已修复：仅在文本前缀不变时保留原选区，
替换仍走原更新语义。

不再逐段向上取整，因此字形位置存在小量累计差异。700pt/340pt 宽度夹具包含正文、硬换行、
列表、引用、代码和空段落；相对字形位置差异在 2pt 内。这是样例容差，不是任意文档的误差上限。
合并文本中段落以换行分隔；跨段 Unicode 选取与复制经过原生 pasteboard 路径验证。

## 固定二进制结果

基线为 `ee6dc1a`（生产 Sources 与主线 `3e7aa29` 相同）。先用未限定段数的版本确认方向，
再限制每组八段。下表是有界版本同一 Release 二进制内三轮交替顺序 A/B 的统计中位数。
两策略均走相同分组容器，只切换是否合并；没有并行编译、CPU 采样或 UI 自动化。

| 场景 / 指标 | 独立段落 | 每组最多八段 |
| --- | ---: | ---: |
| 首次完整下读 median | 9.28ms | 8.91ms |
| 首次完整下读 p95 | 17.76ms | 13.96ms（-21.4%） |
| 下读超过 16.7ms 的步骤 | 28 | 2 |
| 完整上读 median | 6.38ms | 5.61ms |
| 完整上读 p95 | 14.14ms | 12.38ms（-12.5%） |
| 上读后 RSS | 168.55MiB | 168.08MiB |

所有运行均覆盖 200 轮及末尾，再回到开头。独立段落下读 335 步、合并后 334 步；
差异来自分组取整后的文档高度，不能比较仅固定步数的局部片段。记录仍逐项验证完整覆盖。

三轮下读中，文本 representable 的创建/复用入口调用从 2,249 降至 1,283，文本尺寸测量
从 4,991 降至 1,926。创建入口包含回收池复用，不能把它全部称为新分配的 NSTextView。
测量总耗时约 210→182ms；各阶段嵌套，不可累加，也不能直接当作滚动 CPU 占比。

最后补充“换行继承原字体”的修正后，再冻结二进制复验：下读 p95 **17.65→14.50ms
（-17.8%）**，超过 16.7ms 的步骤 **28→2**；上读 p95 **14.07→12.98ms**。
方向与此前三轮一致。`results.json` 保留每个二进制/源文件/夹具指纹、配置、完整覆盖和统计；
最终修正与此前三轮的指纹不同，未混为同一个二进制。本机仓库前缀已从记录中移除，
结果目录使用仓库相对路径；原始结果摘要指纹仍对应本地未裁剪文件。

## 功能与流式边界

- 原生夹具验证宽窄列字形位置、HTTPS 链接、跨段 Unicode 复制、空图片替代文本、
  单独行内代码、追加时节点/选区保留、替换时旧文本清除。
- 128 段回复由 128 个原生文本视图降为 16 个；末组恰有八段，40 次尾部追加均保持
  已有视图身份，每次只重建一组富文本、执行一次文本尺寸测量。
- 末组测量比单段更重，40 次尺寸测量累计约 4.34→9.96ms；最终样本整体更新 p95
  7.66→7.23ms，先前样本也出现过小幅反向波动。这里只确认追加工作有界，**不宣称
  流式性能稳定提升**。整篇 Markdown 仍会解析，一段极大的正文仍可能很慢。
- 现有搜索选区、同 ID 文本变长/变短、宽度变化、会话返回、历史前插阅读锚点检查通过。
  此前有界二进制运行完整 interactions/anchor；最终字体修正运行新增排版检查和完整阅读。
- `paragraphs` 验收已接入 `scripts/check-functional.py` 的现有原生检查流程。

这些时间是修改滚动位置至布局/display/CA flush 的应用侧耗时，**不是硬件滚轮延迟或
显示帧率**。这是正文容器粒度的有效局部优化，不是整个性能问题已经收尾。正在运行的
352 客户端未被这次实验覆盖；正式候选包单独输出，尚未切换真实会话体验，也未推送。

## 复现

```sh
bash scripts/build-navigation-preview.sh
NAVIGATION_GROUP_PARAGRAPHS=0 python3 scripts/run-navigation-check.py reading --output .local/paragraph-baseline
NAVIGATION_GROUP_PARAGRAPHS=1 python3 scripts/run-navigation-check.py reading --output .local/paragraph-grouped
python3 scripts/run-navigation-check.py paragraphs --output .local/paragraph-contracts
python3 scripts/run-navigation-check.py interactions --output .local/paragraph-interactions
python3 scripts/run-navigation-check.py anchor --output .local/paragraph-anchor
```

每次使用新的输出目录，A/B 使用 `--app` 指向同一个冻结应用。生产构建启用有界合并；
环境开关仅存在于 `TRANSCRIPT_CHECKS` 验收构建。构建和 core checks 结果见 `validation.json`。
