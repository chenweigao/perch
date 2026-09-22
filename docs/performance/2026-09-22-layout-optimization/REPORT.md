# 同步布局优化 — 2026-09-22

基线为上游 `0ce3134` 加本任务诊断提交 `c6324b5`，在原独立工作树继续；无其他改动。本轮固定原有 200 轮混合历史、500 个目录会话、1180×600pt、Release／Xcode 27.0。

## 1. 复用文件路径正则

触发：首次阅读／重新挂载历史段落。真实 Time Profiler 链为 `ConversationEntryController.measure → SwiftUI body → ReplyText.attributed → ConversationFileReference.matches → NSRegularExpression.init → ICU RegexCompile`。原 trace 排除前 4 秒后有 271ms 正则编译主线程样本。两条固定规则原先每次重新编译。

修复：仅将相同规则编译为两个静态常量；不缓存消息结果，不更改匹配语法。Apple 的 [NSRegularExpression 文档](https://developer.apple.com/documentation/foundation/nsregularexpression?language=objc)说明实例不可变且可跨线程复用。

验证：WorkbenchChecks 通过（含路径解析／链接范围检查；真实 SSH 因未配置而跳过）；完整历史上下读和末尾覆盖、搜索选区、窗口缩放、会话返回通过。相同场景复录中正则编译主线程样本为 0（排除启动 4 秒，采样不是精确调用计数）。上下读 p95 28.25／33.99ms，没有稳定的整体延迟下降，不宣称修复了滑动卡顿。

真实 Mac 隔离窗口：向上阅读停留第 198 轮，10Hz 流式继续至至少 245 步；切换 B 输入独立草稿，再返回 A，历史位置及 `regex draft A` 恢复。窗口已关闭，没有操作真实用户会话。CUA 偶有动作生效后返回 AXError.failure，均读回确认，工具调用耗时不计入性能。

证据摘要在本目录；原始 trace、完整调用栈、编译日志和固定二进制在 `.local/layout-optimization/`。本轮只做本地提交，不推送、不替换用户应用。

## 2. 已撤销：连续段落合并

尝试把连续的已完成段落放进一个原生文本视图，保留末段独立以避免每个 token 重排整段历史。首次完整阅读覆盖通过，向上读 p95 23.51ms，但这不是固定条件 A/B 改善结论。

原有缩放回归失败：从同一条文字消息的 166pt 偏移跳到相邻 thinking 消息的 75pt。该方案违反阅读位置稳定要求；完整撤销 ReplyMarkdownView 改动，没有调整断言、隐藏消息或混入锚点补丁。失败 patch、回放数据和锚点详情保留，隔离失败二进制位于 `.local/layout-optimization/ParagraphRejected.app`。后续构建使用原渲染器。

## 3. 图片在后台按显示尺寸解码

触发：4K PNG 进入视口或切到含图会话。原执行路径是 `NSImage(data:)` 留下惰性解码，在主线程 Core Animation 提交时触发 PNG 像素转换。

修复：用单独的 actor 串行处理静态位图，ImageIO 按 600pt 最大阅读宽度乘显示缩放生成缩略图，并要求立即解码；回到主线程只发布图像。进入解码前及发布前检查任务取消。显示缩放变化会重新加载适合的新像素尺寸。向量／多帧格式保留既有 NSImage 处理，原图存储按钮的请求和数据不变。后台处理没有新增消息缓存、预加载或并行解码池。

Apple 的 [ImageIO 立即解码选项](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)明确区分创建时解码与首次绘制时解码。

验证：

- 固定 4096×3072 PNG 得到 1200×900 的实际 CGImage；8×4 小图不放大，多帧 GIF 保留 2 帧，取消任务在解码前退出。隔离构建中的线程断言覆盖每次解码，均未在主线程运行。
- 同一内容、窗口和 Release 方式的 Time Profiler 回放：之前主线程 PNG 解码样本 95ms；之后主线程未采到，后台 PNG 解码样本 112ms、缩略图生成 139ms。数值为累计采样权重，彼此包含，不是单次掉帧耗时或总体加速比。
- 首次 A/B 自动回放有测量缺口：后台任务结束不等于新的图片高度已传播到文档，原 driver 可在 15pt 的名称占位行结束。两份未就绪结果及失败的任务计数尝试保留；不以它们的较低 RSS 或不同高度宣称性能收益。已改为等待固定 4:3 图片的实际显示高度，超时即失败。最终图片行 363pt、文档 106770pt，与原基线相同，全部 200 轮和图片末尾覆盖通过。
- 缩放、搜索选区、返回会话在含图场景通过；无图阅读也通过。新检查读取真实 CGImage 像素尺寸，原先用 NSImage 的表示对象尺寸做探针未得到实际像素维度，失败记录保留。
- 真实 Mac 隔离窗口：图片可见、宽高比正常；中文粘贴及 Shift+Return 多行草稿；10Hz 流式至 300 步时仍读第 198 轮；A/B 草稿隔离及返回恢复；Bash 输入／输出展开；反向滚动后回到第 201 轮，300 个片段完整可见。窗口已关闭。中文粘贴不是 IME 组合输入验收，CUA 调用耗时不是硬件点击延迟。

## 当前边界与后续

两项保留的修复分别移除了重复正则编译和静态位图主线程解码；**没有证明整体滚动 p95 稳定降低，主要的冷行同步创建／布局仍待优化**。段落合并因锚点回归已撤销。下一项最值得做的是在不改变行布局契约的条件下，细分冷宿主创建和布局图构造；不能重新采用已失败的段落合并而放宽锚点断言。

单张合成 PNG 与两帧 GIF 不等于相册、远程大图、所有格式、色彩精度或动画播放验收。串行解码队列在多图连续滚动时的取消及内存峰值仍需专门验证。真实 SSH、输入法、显示帧级验收仍沿用上一轮的未验证边界。

复现：

```sh
scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py image --output .local/image-check
NAVIGATION_IMAGE_FIXTURE="$PWD/Tests/Fixtures/stutter-map-4k.png" \
  python3 scripts/run-navigation-check.py reading --output .local/image-reading
python3 scripts/profile-navigation.py reading --image-fixture Tests/Fixtures/stutter-map-4k.png --output .local/image-profile
```

`--app` 可选取固定的 A/B 预览二进制；图片阅读断言使用本仓库固定 4:3 PNG。运行报告的 commit 字段是当时工作树 HEAD，必须结合 source_sha256／fixture_sha256 与相应修改核对，不能单用 HEAD 推断当时没有未提交改动。

## 最终交付验证

已 rebase 到上游 `ae53ec4`（新增原生侧栏／标题与构建脚本修复），无冲突；相关正文和图片优化路径未被上游改动。合并后通过完整 `scripts/build.sh` Release 构建、严格签名验证、WorkbenchChecks、图片检查以及含图的搜索／缩放／会话返回回归。构建使用上游指定的 SwiftPM native；产物最低 macOS 14.0、链接 SDK 27.0。已有 NativeAgentConnection、WorkbenchView 的编译警告未在本轮扩大处理。

产物为此工作树的 `build/Perch.app`，未启动该正式应用去读取真实用户会话，未替换用户正在使用的版本。源改动、报告和失败证据均本地提交，未推送或发布；隔离窗口与录制器已退出。最后构建／文件指纹及检查状态见 `delivery.json`。原始 trace 和失败二进制仍在 `.local/layout-optimization/`。
