# #326 首次 CI 失败与数学对照构建修复

## 失败（head 933a070）

Actions run `43209884221` 的 core job `131157672440` 只在 math-performance 失败：
`Typeset/draw regression exceeds 15% at 128`。汇总 job `131161827782` 只是正确传播
core 失败，不是另一个产品构建错误。其他原生组通过。

128 公式 combined cold+draw：baseline 三轮 317.949 / 459.595 / 277.624ms，candidate
360.136 / 430.784 / 336.731ms。最优值比约 1.213，确实触发现有 1.15 门槛，不能略过。
原始 summary：[initial-failure.json](initial-failure.json)。这些是共享 runner 采样，
不能与下文 Mac mini 的绝对值比较。

## 发现的构建混杂（不声称唯一根因）

CoreSources 有变化时，math baseline 会 fresh build SwiftMath；candidate 在
`PERCH_REUSE_PREBUILT=1` 下使用产品构建的对象。产品 `scripts/build.sh` 已应用
`swiftmath-app-resources.patch`，旧 math fresh-build 分支却没有应用：baseline 使用
上游 Bundle.module 路径，candidate 使用产品的 app-resource fallback。即使 lock pins
相同，依赖源码条件也不同，不能当成公平的产品对照。

## 修复（仅构建/测试工具，产品和门槛不改）

- 每个 variant 从它自己的 revision 导出 SwiftMath 资源补丁。
- fresh build 先 resolve，再验证/应用该补丁，再编译 SwiftMath/Core。
- prebuilt reuse 除 Core/pins 相同外，还要求 revision 补丁相同、checkout 已应用目标补丁。
- 补丁 bytes 纳入 source_input_sha256，单独记录 swiftmath_patch_sha256。补丁变化不得
  被当成 A/A，也不能错误复用另一版本对象。
- 保持 typeset 1.15、内存、解析语义/增长及其他比较门槛不变，没有跳过失败或设置放行变量。
- 产品 `Sources/AgentWorkbench` 与 round 6 Core 优化源码均未追加修改。

新增真实 Git patch + stub compiler 合约测试：fresh 编译前已打补丁；fresh/reused 同输入
身份一致；unpatched prebuilt 必须回退；revision 补丁变化必须改身份并拒绝旧对象。
相关 22 个数学工具测试通过，portable 10/10。

## 独立 Mac mini 复核

Aqua 内以 baseline 0711150、candidate 933a070 + 当前构建工具运行：两边补丁 hash 同为
`68686f9cd8fbe4b1134ace3a22f162828b9d4bd89eb84816f050379aa06bb855`。
Core 输入仍有真实差异，因此 relative gates **仍 applied**，不是伪装成 A/A。

128 公式最优 combined：124.844→124.897ms，比 1.00043；完整数学合约和全部比较通过。
[local-matched-build.json](local-matched-build.json)。同一 candidate binary 的独立 A/A
控制也通过且保留计量/语义检查；它不用于宣称源码改善或替代真实 A/B 门槛。
[local-aa-control.json](local-aa-control.json)。

这证明修复后的本机匹配构建可通过，没有证明旧 CI 波动完全由补丁导致，更不代替 CI。
修复 head `ace9d7d` 的八项新 CI 已全部成功（run `43215468016`，含 core 数学门槛），
新的独立评审无可操作发现并复跑22个数学工具测试；最终Codex回执审阅该head、无重大问题。
汇总评论仍有早于最终回执的 running 标记，合并审计已说明差异，没有伪称汇总已更新。
确认无inline意见及mergeable/CLEAN后，2026-11-12 20:27 按授权以 sha=ace9d7d 原子匹配
合并为 `74dee39961babdaa8f3f0118c6b16a9261b6fb6b`。最初失败记录未删除，门槛未降低。
