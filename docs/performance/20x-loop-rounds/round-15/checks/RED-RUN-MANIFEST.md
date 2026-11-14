# Red-run provenance manifest（复核发现 4 补强；2026-11-14）

未修复 SWAR 减法掩码（c8dffd3 产品态）在扩展钉死下变红的两次运行记录。
所有路径已脱敏；日志文件与本清单同目录。

## 1. 原始红跑（归档日志 `checks-red-unfixed-swar.log`）

- 时间：2026-11-14（Linux 开发机，会话 shell，v2 A/B 之前）
- 产品态：**c8dffd3**（未修复：减法型 has-zero 掩码）
- 测试态：**3f255da**（扩展钉死、标签修复前；precondition 位于
  LineCountScanTests.swift:37，与日志崩溃帧一致）
- 命令：`swift build -c release --product WorkbenchChecks`（Swift 6.3.3，
  x86_64 Linux）后运行二进制，stdout+stderr 合并捕获
- 退出状态：**132**（SIGILL，precondition failure，崩溃于穷举走查）
- 局限（发现 4 所指）：当时**未捕获二进制 sha256**，构建身份由日志崩溃帧
  的行号/符号间接佐证——由下述复现跑补全。

## 2. 全溯源复现（归档日志 `checks-red-repro-unfixed-swar.log`）

- 时间：2026-11-14 21:03 CST
- 产品态：`git worktree add --detach <scratch-red> c8dffd3`（未修复掩码；
  worktree 隔离，主树未动）
- 测试态：**最终 head**（标签修复 + 邻接计数器；precondition 移至
  LineCountScanTests.swift:39——崩溃发生在穷举走查、早于任何打印，标签
  变更不影响红结果；两测试文件按字节拷入 scratch）
- 构建：`swift build -c release --product WorkbenchChecks`，**build exit 0**
- 二进制 sha256：**7b7933b66394f77f35d6917e7741bb7ff0a1d9c2f3578d5045157da69bfce76e**
- 命令：`.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks`（无环境
  变量，全套检查模式）
- 退出状态：**132**（Illegal instruction, core dumped）
- 崩溃帧：38 条 PASS 后，`specialized check #1 (_:) in
  checkEditStatsLineCountScan()` @ LineCountScanTests.swift:39（穷举走查
  walk 帧在栈上）
- 说明：release 构建未打印自定义 precondition 消息文本；评审方对未修复
  模型的独立重放定位首个失败语料为 `"\n\u{000B}汉汉"`（未修复 SWAR 计 3、
  oracle 为 2），与穷举走查顺序及崩溃前缀一致。

## 3. 绿对照（最终 head；产品与 3f255da 逐字节相同，仅测试标签/计数器差异）

| 侧 | 产品 | 测试 | 结果 | 二进制 sha256 | 日志 |
| --- | --- | --- | --- | --- | --- |
| Linux 候选 | 3f255da | 最终 head | exit 0，96 PASS + 1 SKIP | d9d869a8b31c0421d4a1cb89f889c1db2322ba973bada6025a4499e391f8c4a0 | `checks-cand-final-linux.log` |
| Linux matched baseline | 9c12eb9 | 最终 head | exit 0，96 PASS + 1 SKIP | 8821673c3eef27c424a394a2903ee91c0530796fb005478ec1559d786268a2c7 | `checks-base-final-linux.log` |

钉死行打印（两侧一致）：`PASS: edit-stat line counting matches the
Character-split oracle across 27885 cases (22302 containing VT/FF, 16811
with an LF→VT or CR→FF adjacency)`——22,302/16,811 与评审独立重放逐值
一致。A/B 采纳数据仍锚定 3f255da 二进制（Linux dbc21b2e…/Mac 2bc1e15e…）：
bench 夹具源与产品源在最终 head 均未变化。
