# After 回收与消费的实际回执

2026-11-19，当前真实 GUI 候选仍为 `7e66eb2e5a9dac92eea8d6178e55e7ab5f38e554`。

- Mac 打包 SSH 和 SCP 在原命令中分别打印 `package_ssh_exit=0`、`transfer_exit=0`，整个传输工具回执 exit0；原包与 Mac 摘要匹配，未修改原件或全局配置。
- 本地解包命令打印 Python 的 `DeprecationWarning: Python 3.14 will, by default, filter extracted tar archives and reject files or modify their metadata. Use the filter argument to control this behavior.`。实际解包前逐个确认无绝对／上跳路径、无重复名、仅目录或普通文件、无 AppleDouble，并验 68 个 PNG magic。告警不是数据／视觉失败，也不冒称使用了未执行的过滤参数。
- 解包验证、原件比较、原件发布、元数据发布、发布副本比较、派生生成各有实际 `status: passed` 输出及保留的 JSON。整体 shell 最后的 `jq ... | head -n 50` 只用于显示摘要，在 `set -euo pipefail` 下截断后工具返回 **141**。该整体回执必须保留为 141，不能说全命令 exit0，也不能把它误归类为 Mac gates 或像素比较失败。
- 后续有界 `jq` 命令实际 exit0，读取既有 JSON 的 34 组与 18 个全窗口不变组；未重拍、未重跑比较、未改容差／冻结区、未重写原负证据。
- 原始工具会话 ID：传输 `96229`，消费 `54124`。会话标识只定位历史执行，不是可复用作业 ID或独立评审结论。
