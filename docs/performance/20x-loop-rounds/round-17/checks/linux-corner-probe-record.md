# Linux corner-probe record（re-review finding 1 处置期间的实测取证）

钉死的平台条件断言基于以下**实测**输出（临时 print 探针插入
`checkNormalizeDelimitersByteGuard`，读取后移除，未进入任何提交；断言本身
已把数值钉死在测试内）。平台：Alibaba Cloud Linux 3 x86-64，Swift 6.3.3，
WorkbenchChecks release。

## 探针 1：Prepend 角落（修复后的候选构建，含前边界检查）

输入 `"\u{0600}\\(x\\)"`（UTF-8: D8 80 5C 28 78 5C 29）：

```
PREPEND_ACTUAL: [216, 128, 36, 120, 36] hasMath=false
```

即输出文本 `"\u{0600}$x$"`（D8 80 24 78 24）、无 math run——**源被转换**。
解读（机制为推断，行为为实测）：Linux corelibs 的子串 `contains("\(")`
未应用 GB9b（U+0600 未与反斜杠合并 → 搜到 `"\("` 对 → 守卫开门 →
字节级 Boundaries 转换）；而下游 splitInline 的 stdlib Character 迭代
**有** GB9b（转换出的 `$` 与 U+0600 合并为一个 Character → 无裸 `$`
开启符 → 不提取 math）。同一管线中两套 Unicode 行为并存——这正是**旧
产品在 Linux 上的既有行为**（未改产品 76940c0 + 本钉死的基线构建同值
通过，见 checks-base-final-linux.log 的 98 PASS + digest d90ac2cad4b58020），
字节守卫的不确定对回落各平台自有 contains，逐位复现之。

## 探针 2：扩展括号角落（同构建）

输入 `"\\(\u{0308}x\\)"`（括号被组合符延长、全源无精确对）：

```
EXT_ACTUAL: [40, 204, 136, 120, 41]
```

即 `"(◌̈x)"`——**未转换**（cmark 反斜杠转义已解析），与 macOS 行为一致：
两平台的搜索语义都把带延长的括号 Character 判为 ≠ `"("`。此角落为
**双平台统一断言**（非条件分支）。

## 与 macOS 侧的关系

评审方以 Python/ICU 独立复现了 macOS 的 GB9b 分段（`"\u{0600}\\(x\\)"`
的 Characters 为 `[U+0600+反斜杠, "(", …]`，contains 不中 → 字面保留）。
Mac 侧断言（`joinedParagraphText == "\u{0600}(x)"`）在黄金捕获/正式 A/B
的基线与候选两侧运行并通过（99 PASS），即 macOS 的旧行为与新守卫行为
同为字面保留。两平台各自钉死各自的既有行为；黄金 fuzz 摘要语料按设计
不含 Prepend 标量，单一摘要值跨平台不变（d90ac2cad4b58020）。
