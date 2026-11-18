# Round 0 基建伪影链

所有 GUI 作业均由 Mac mini 的 PerfRunner 串行执行。失败作业没有被当作视觉或契约证据；
最终证据只取 `contracts/perfrunner-capture.log`、`contracts/perfrunner-gates.log` 与
`baseline/manifest.json`。

| 作业 | 结果与处置 |
|---|---|
| `style-r0-probe` | 原 `native-design` 只落 view-cache PNG，未落 composited 图；透明像素与 hover 状态不可作为稳定基线，改为显式静态 fixture + 父进程 `screencapture`。 |
| `style-r0-screen-probe` | shell/Python 直接调用全屏、区域、窗口三种 `screencapture` 均失败；系统 TCC 仅显示既有 Node 授权。 |
| `style-r0-node-screen-probe` | 通过既有授权 Node spawn 原生 `screencapture`，全屏截图 exit 0；不新增授权、不修改 TCC。 |
| capture v1 | `DynamicTypeSize?` 编译错误；改为当前 SDK 的非可选默认值 `.large`。 |
| capture v2 | bundle 路径多一层 `Contents`；修正 `parents[2]`。 |
| capture v3 | 静态化 busy 后仍执行 live-status 断言；只在截图模式跳过该断言。 |
| capture v4 | 直接 `screencapture -l` 返回 `could not create image from window`；转入 Node 权限链探针。 |
| capture v5 | Node 将 `-x` 等参数当作自身选项；用 `--` 分隔并实测 argv。 |
| capture v6 | 18pt 在默认 14pt 断言处中止；字号覆盖移到默认检查之后。 |
| capture v7 | main/sidebar/composer 双跑稳定，workbench 运行中圆环造成约 12×12 像素漂移；截图 fixture 改为静态会话。 |
| capture v8/v9 | `accessibilityReduceMotion` 环境只读且无视图 modifier；移除该路径，不改生产代码。 |
| capture v10 | 23/23 场景通过；纯 Python 解码耗时 400.6s。 |
| capture v11 | 优化为字节一致时免解码，23/23 再次通过；耗时 258.2s。 |
| capture v12 | transcript navigator 需要 `TRANSCRIPT_CHECKS`，宿主不可用；移除该依赖。 |
| capture v13/v14 | 24/24 通过。确认 preview PNG 顶部是 alpha=0 的系统框外区域，不是白色标题栏；暗色评审只看内容区。滚动场景保留长对话底部锚定。 |
| capture v15 | `CGEvent.post` 缺少 `tap:` 标签，编译中止；修正。 |
| capture v16 | 真实 wheel 事件未离开底部锚点，截图前置断言中止；不再把回顶控制纳入本轮范围。 |
| capture v17 | 中间 24/24 通过；后续评审发现部分命名变体为重复/no-op，不能作为最终覆盖。 |
| capture v18 | inspector 关闭与矩阵修正后，`main-scroll` 末段文字抗锯齿漂移；纯文本化该 fixture 并延长稳定等待。 |
| capture v19 / gates v8 | 被 v20 取代且尚未开始，排队文件已取消，未产生证据。 |
| capture v20 | 最终复核作业；18 个有效场景，结果见最终 manifest。 |
| gates v1 | 因 capture v12 未生成宿主 app，native-design 阶段失败；产品 build、5/5 冷启动、macOS WorkbenchChecks 已通过。 |
| gates v2/v3 | 在中间分支头全套通过；最终头仍重跑，不借用为最终证据。 |
| gates v4/v5 | 中间 fixture 迭代对应的非最终作业，日志保留但不作为最终证据。 |
| gates v6/v7 | 中间代码头全套通过；最终头仍重跑，不借用为最终证据。 |
| gates v9 | 最终复核作业，结果见 `contracts/perfrunner-gates.log`。 |

中间分支头被 amend 后只保留一个 round 0 conventional commit；本目录保留各次作业日志，
便于追溯，不把中间 SHA 当成最终交付。归档日志中的本机绝对路径已统一替换为
`/Users/<mini>` 或 `/home/<dev>`；命令结果、退出码、提交 SHA 与图片哈希不变，
`check-public-source.py` 最终为 0 findings。
