# 同步 main 后的体验包 — 2026-09-23

按用户要求 fetch 并将本任务分支无冲突 rebase 到 `origin/main 9eaa00e`。本次带入 `9743a5a` 新回复按钮描边、`80bfeb4` 交错过程记录折叠和 `9eaa00e` 配置 HTTP IP 摘要地址支持；保留正则复用与静态图片后台缩略解码。同步后的任务 HEAD 为 `f262ef5`，本轮唯一后续代码修改是过期测试断言，不改变产品行为。

`scripts/build.sh` 完成 Release 构建，产物 `build/Perch.app`，最低 macOS 14.0、链接 SDK 27.0。`codesign --verify --deep --strict` 通过；这是本地 ad-hoc 签名，不是公证发布。文件指纹与原始日志入口见 `build.json`。

首次 WorkbenchChecks 在 `ToolVisibilityTests.swift:40` 触发 precondition，Debug 重放和崩溃报告确认同一断言。新折叠语义将已完成的思考放在 activity 阶段内，旧断言仍把思考当成非 activity 正文。更新为分别核对可见正文和阶段内保留的思考，并保留原有源顺序、内容完整和工具稳定 ID 检查。完整 Release WorkbenchChecks 重跑通过；真实 SSH 因未设置 `WORKBENCH_LIVE_HOST` 跳过。失败日志保留于 `.local/experience-build-20260923/`。

同步后重建隔离 Navigation Preview，200 轮完整上下阅读与末尾覆盖通过；搜索选区、缩放和会话返回检查通过。精简结果见 `reading.json`／`interactions.json`，原始回放与编译日志在 `.local/experience-build-20260923/`。新 main 改动了消息折叠和布局，上一轮性能数字不能当成本体验包的测量；本轮回归也不证明整个 App 已流畅、真实模型可用或新摘要地址已在线验收。

没有启动正式应用或操作用户会话；没有推送、合并或发布。本地提交仅记录测试适配及本构建证据。用户可以自行打开此工作树的 `build/Perch.app` 体验。
