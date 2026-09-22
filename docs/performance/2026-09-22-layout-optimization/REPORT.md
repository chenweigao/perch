# 同步布局优化 — 2026-09-22

基线为上游 `0ce3134` 加本任务诊断提交 `c6324b5`，在原独立工作树继续；无其他改动。本轮固定原有 200 轮混合历史、500 个目录会话、1180×600pt、Release／Xcode 27.0。

## 1. 复用文件路径正则

触发：首次阅读／重新挂载历史段落。真实 Time Profiler 链为 `ConversationEntryController.measure → SwiftUI body → ReplyText.attributed → ConversationFileReference.matches → NSRegularExpression.init → ICU RegexCompile`。原 trace 排除前 4 秒后有 271ms 正则编译主线程样本。两条固定规则原先每次重新编译。

修复：仅将相同规则编译为两个静态常量；不缓存消息结果，不更改匹配语法。Apple 的 [NSRegularExpression 文档](https://developer.apple.com/documentation/foundation/nsregularexpression?language=objc)说明实例不可变且可跨线程复用。

验证：WorkbenchChecks 通过（含路径解析／链接范围检查；真实 SSH 因未配置而跳过）；完整历史上下读和末尾覆盖、搜索选区、窗口缩放、会话返回通过。相同场景复录中正则编译主线程样本为 0（排除启动 4 秒，采样不是精确调用计数）。上下读 p95 28.25／33.99ms，没有稳定的整体延迟下降，不宣称修复了滑动卡顿。

真实 Mac 隔离窗口：向上阅读停留第 198 轮，10Hz 流式继续至至少 245 步；切换 B 输入独立草稿，再返回 A，历史位置及 `regex draft A` 恢复。窗口已关闭，没有操作真实用户会话。CUA 偶有动作生效后返回 AXError.failure，均读回确认，工具调用耗时不计入性能。

证据摘要在本目录；原始 trace、完整调用栈、编译日志和固定二进制在 `.local/layout-optimization/`。本轮只做本地提交，不推送、不替换用户应用。
