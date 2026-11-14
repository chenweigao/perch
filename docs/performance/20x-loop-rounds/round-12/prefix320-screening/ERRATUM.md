# Erratum（round-12 独立评审 Q7 处置，2026-11-14）

对 [SCREENING-RESULT.md](SCREENING-RESULT.md) 的三处更正与一处补强。原文件保留原样，
以本文件为准；更正不改变"否决该候选"的结论。

1. **单位标注错误**：原文"µs/call medians"列出的数值实为**毫秒**
   （`microbench-mac.swift:162` 将纳秒除以 1e6）。CJK 的 v0=0.0035 即约 3.5µs/次，
   short≈0.4µs、longAscii≈1.3µs。相对百分比不受影响，否决结论不变。
2. **"whole-text pass"措辞过宽**：两个被否决实现的折叠/计数走查都带 320 标量上限
   （可在第 321 个标量处中止），并非总是走完整文；被否决的机制是"在字素行走之外
   **额外**付出一次带上限的整段扫描"，对 >320 标量的 fixture 文本该扫描到上限才中止，
   仍然覆盖了大部分文本。另外，两个被否决实现不能证明"不存在更便宜的 sound 替代"，
   只能证明**这两类**替代不成立；INDEX 否定清单的措辞已相应收窄。
3. **等价性验证的归属错误**：41,092 对差分语料验证的是
   `equivalence-prototype-v2.swift` 中的 `excerptNew`（带上限折叠 + substring 回退的
   融合设计，见该文件 124 行注释），而筛选计时表中的 v2 行测量的是
   `microbench-mac.swift:125` 的 count-first 变体——**两者不是同一函数**。原文把
   fuzz 结论写成了覆盖被测 v2，属于归属错误。被计时变体的等价性未经过同规模差分
   验证（候选已否决，不再补验）。
4. **补强（可验证性）**：原筛选的有效计时输出未归档（保留的
   `12-round12-microbench.log` 记录的是被 SIGKILL 的裸 swiftc 尝试）。评审后已用
   留存的 SwiftPM scratch 包（mini 上 `~/Library/Logs/perf-loop-20261113/r12mb`）
   重跑一次并归档完整输出：[microbench-rerun.log](microbench-rerun.log)。重跑中位数
   与原始记录的逐次对比见该日志与原文表格；相对结论（v1/v2 在 >320 标量文本上均为
   正开销、仅短文本受益）以重跑数据为准。
