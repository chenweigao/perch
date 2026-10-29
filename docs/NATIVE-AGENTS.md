# OMP / Qoder CN / Qoder / DeepSeek / Codex / Claude Code 原生对话

Mac 界面、远端执行。⌘N 选择 Kimi、OMP、Qoder CN、Qoder、DeepSeek、Codex 或 Claude Code，默认沿用当前目录，也可选择最近目录；名称由第一条消息生成，自动关联当前任务组。置顶、分组、待处理队列与工作现场共用，顶部不恢复重复标签栏。

## 已核对的运行时

- OMP 18.1.16：先验证 `--mode rpc` 的消息流和审批，再使用同协议的 `--mode rpc-ui` 启用内置 `ask` 工具。创建会话时把所选 `always-ask`、`write` 或 `yolo` 显式传给 `--approval-mode`；会话内不动态切换。接收 message 事件、工具调用/结果及 extension UI 请求；协商 v2，按帧序号与字节数校验分块。
- Qoder CN：官方 `@qodercn-ai/qodercn-agent-sdk` 1.0.45，发行包 runtime-manifest 明确匹配 CLI 1.1.58。通过 SDK `query`、`canUseTool`、`interrupt` 和 `resume` 接入已安装的 `qoderclicn`，未使用 ACP 推断兼容性。沿用远端 CLI 登录；每次 `query` 带当前权限模式，切换从下一轮生效。需确认的调用由 Mac 界面返回本次 allow/deny；`bypassPermissions` 还会显式设置 `allowDangerouslySkipPermissions`。
- Qoder（国际版）：官方 `@qoder-ai/qoder-agent-sdk` 1.0.51，接入已安装的 `qodercli`（实机核对 1.1.67，官方安装脚本的原生可执行文件）。与 Qoder CN 共用同一 worker 事件协议和权限模型，worker 按桥传入的 `sdk` 字段动态加载对应 SDK 包。
- DeepSeek Harness（dsh）0.1.5-rc.1：走标准 ACP v1（`dsh --profile acp`，stdio JSON-RPC）。已实测 `initialize`、`session/new|list|resume`、`session/set_config_option`（model 与 reasoning_effort）以及无凭据时 `session/prompt` 的报错路径；`session/cancel` 与 `session/request_permission` 按官方 ACP 契约接入。每会话一个进程，握手完成后才放行 prompt；dsh 只发已提交的消息块（无增量流），审批以 select 卡片呈现，选项标签映射回不透明 optionId。dsh 是 developer preview，升级版本必须重跑协议核对。
- Codex CLI（安装不钉版本，跟随官方 latest）：按 `app-server generate-json-schema --experimental` 生成的完整 schema 核对协议；0.155.1 实机验证创建、无工具 turn、恢复、归档、恢复归档与删除，0.162.1 复核 schema 中 model/list、thread/start|resume|archive、thread/items/list、turn/start|steer|interrupt 均保留，并实机验证创建、归档与模型目录。升级后若协议行为变化须重跑核对。只使用 `codex app-server --listen stdio://` 的 JSON-RPC，不启动 PTY，也不抓取终端画面。创建与恢复分别调用 `thread/start`、`thread/resume`，Perch 会话 ID 就是原生 thread UUID；历史通过 `thread/items/list` 恢复。发送、运行中引导和停止分别使用 `turn/start`、`turn/steer`、`turn/interrupt`。流式正文、思考、计划、工具和 token usage 转入统一对话；`item/reasoning/summaryPartAdded` 与 `summaryTextDelta` 作为结构化 `activity_summary` 元数据传给活动叙事，不把原始 reasoning 当作摘要。`item/completed` 的权威 summary/content 覆盖增量草稿并标记 final，`thread/items/list` 恢复历史时也生成同样元数据。模型及 reasoning effort 来自 `model/list`，创建和切换时均拒绝目录之外的值，切换仅用于后续 turn。command、file change、permissions、tool input 与 MCP elicitation 等 app-server 反向请求全部显示在 Mac 上并等待明确回答，不自动批准或静默拒绝。输入框支持附件（一次最多 5 个、单个 10MB）：桥把文件落到远端 `attachments/` 目录，图片以 `localImage` 输入项随 `turn/start` 发送，其他文件在文本中附远端路径供读取；运行中引导（steer）不带附件，带附件的消息排队到下一轮。
- Claude Code：官方 `@anthropic-ai/claude-agent-sdk` 0.3.302，驱动远端已安装并登录的 `claude` CLI（建议 2.1.302，与 SDK 同版；SDK 0.3.N 对应 CLI 2.1.N）。0.3.302 含 0.3.284 的修复：后台子 Agent 结束唤起的追加轮不再因 stdin 已关而让 hook、`canUseTool`、SDK MCP 调用失败（"Stream closed"）；升级经 native service v8 触发各机器重装组件。消息类型与 Qoder SDK 同构（system init / assistant / user / stream_event / result），桥与 Mac 复用同一 worker 事件协议：SDK `query`、`canUseTool`、`interrupt`、`resume`。沿用远端 CLI 登录与凭据，桥不接触；每次 `query` 带当前权限模式，切换从下一轮生效；`bypassPermissions` 同时显式设置 `allowDangerouslySkipPermissions`。模型目录由 SDK `supportedModels()` 读取，返回当前 CLI/账号支持的入口、alias 的 `resolvedModel` 与各入口的 effort，不发送 prompt，也不代表已验证模型鉴权；留空使用 CLI 默认模型。目录与创建时模型/effort 需 native service v11，旧桥按提示更新组件即可。输入框支持附件（一次最多 5 个、单个 10MB）：桥把文件落到远端 `attachments/` 目录，图片（png/jpeg/gif/webp）经 SDK streaming-input 以 image 块发送，其他文件在文本中附远端路径供 Read 查看；历史中只保留 `[图片: 名称]` 标记，不提供图片本体回看。每轮最后一条主循环 assistant 消息的 per-request `usage`（input+cache+output 即当前窗口占用）与 result 的 `modelUsage` 的 `contextWindow` 转成上下文余量上报；result 自带的 `usage` 是整轮跨请求合计，不代表窗口，不能用。result 之后 worker 再请求 SDK `getContextUsage`（summary），带回解析后的压缩窗口（1M 模型默认可能是 200K）覆盖声明上限；旧 CLI 不支持时保留估算读数。无回复的轮次与归零的崩溃结果不覆盖有效读数。worker 与 Codex 一样注入代理环境（检测到本机代理时读取 `~/proxy.env`），否则 CLI 回连功能开关/遥测的请求会静默卡住首轮。

参考：[OMP 18.1.16 RPC 文档](https://github.com/can1357/oh-my-pi/blob/v18.1.16/docs/rpc.md)、[Qoder CN 官方 SDK](https://docs.qoder.cn/cli/sdk/overview)、[dsh ACP 包说明](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/acp/acp)、[Codex app-server](https://github.com/openai/codex/tree/main/codex-rs/app-server)、[Claude Agent SDK](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk)。

## 远端托管

`remote/native-agent-service.py` 是仅监听远端 127.0.0.1 的独立进程，通过系统 SSH 隧道访问；持有 OMP 的 stdin/stdout、Qoder 与 Claude 的 SDK worker、dsh 的 ACP 进程与 Codex app-server。Mac 断线、退出不关闭这些管道，因此 Agent、工具及待审批请求继续存在。远端使用随机访问令牌，目录/文件限定当前用户访问，Mac 只在内存持有令牌。

远端安装位置：`~/.local/share/agent-workbench/native`。会话目录保存工作台转译后的消息、状态和上游 resume 标识；不会保存 OMP get_state 中的模型 headers、认证配置。Codex 身份与凭据由远端 `codex` CLI 管理，支持官方登录和自定义模型供应商；桥保存 thread UUID、所选 HOME 和供应商标识，不保存凭据。SDK 使用独立 npm 目录，不替换全局 CLI。dsh 会话使用独立的 `DSH_HOME`（托管目录下 `dsh-home/`），不读写用户的 `~/.dsh`；遥测显式 `DSH_TELEMETRY_MODE=DISABLED`；模型凭据沿用远端 `DEEPSEEK_API_KEY` 环境变量，桥不接触。

```sh
# App 内可直接点击「安装 / 更新桥接组件」，也可显式指定机器与 Agent：
./scripts/install-native-service.sh my-server --provider=omp
./scripts/install-native-service.sh my-server --provider=qoder
./scripts/install-native-service.sh my-server --provider=dsh
./scripts/install-native-service.sh my-server --provider=codex
./scripts/install-native-service.sh my-server --provider=claude
# 保留旧的全套安装方式：<host> 或 <host> --with-dsh
```

所有桥接目标需 Python 3。OMP 使用已配置的 omp 18.1.16，不要求 npm；Qoder CN 使用 Node.js/npm 与已登录的 qoderclicn 1.1.58；Qoder 国际版使用 Node.js/npm 与已登录的 qodercli（官方安装脚本，实机核对 1.1.67）；Claude Code 使用 Node.js/npm 与已登录的 `claude` CLI；dsh 安装固定版本的 Python SDK wheel，不要求 Node.js；Codex 使用已安装并完成官方登录或自定义供应商配置的 `codex` CLI，不要求桥接安装器运行 npm。安装脚本禁用 npm 生命周期脚本，SDK 明确使用现有 CLI。桥接协议版本由 `remote/native-agent-service.py` 的 `SERVICE_VERSION` 与客户端的 `RemoteSetup.bridgeServiceVersion` 共同声明，两者必须相等（`scripts/check-version.py` 强制校验）。“服务连接”检查读取远端脚本里的该常量，版本过旧提示重新安装桥接组件，版本过新提示升级 Perch，并显示当前生效的版本；连接时再按 `/health` 校验实际运行的服务。Mac 连接时启动或复用托管服务；安装或更新文件本身不会终止托管服务，后续检查会验证协议版本，并只在所有会话空闲时自动替换旧服务，存在运行中任务、待审批请求或异步命令时保留旧服务并提示等待。

`/health` 同时上报 `implementation`（运行中服务自身源码的 sha256 前 16 位）与 `startedAt`，`--ensure` 两者都比对：协议号相同但源码不同（改动没有提升 SERVICE_VERSION，或服务早于该字段）同样走空闲替换流程，有活动任务时照旧保留旧服务并提示等待；本机源码读不出来时退回只比协议号，避免每次检查都重启健康服务。向导以「运行进程」信息行显示运行中的源码指纹与启动时间。注意这只覆盖桥自身：Agent CLI 与 SDK worker 在每个会话启动时从磁盘读取，升级后已运行的会话仍是旧版本，从下一个会话生效。

Mac 保持 400ms 调度周期；目录在有运行任务时每 2 秒、全空闲时每 5 秒刷新。选中对话运行中、有审批或待发消息时按正常周期读取 revision，空闲时每 2 秒读取。发送回执照常核对；切换会话立即加载，目录变化与历史分页竞态触发下一次读取。未变化时不传输或重建整段历史。只在会话元数据变化时更新全局队列，流式内容局限于原生对话视图。正文、Markdown 和按发生顺序展示的工具摘要与 Kimi 共用；工具完成后仍保留摘要，仅参数和输出按需展开。

## 模型选择

桥的 `/models` 是合并目录，每条带 `agent` 字段说明谁能路由它：OMP 来自 `omp models --json`（18.1.16 输出 `{"models":[...]}` 包装，桥负责展开），Qoder CN 与 Qoder 分别来自各自 SDK daemon 的 `accountInfo()` 取得 userId 后调用 `getModels({ fetchStrategy: "live", uid })`，Claude Code 来自 SDK `supportedModels()`，dsh 来自 ACP config options（首次握手后缓存到 `dsh-catalog.json`）。Mac 端按当前 Agent 过滤；两套 Qoder 目录分别标记 `qoder` 与 `qoderintl`，不会跨区域串用。

新建任务面板里 Kimi、OMP、Qoder CN、Qoder、dsh、Codex 与 Claude Code 都可从对应的可搜索目录选择模型；只有运行时允许的入口继续接受目录外 id。模型留空表示沿用运行时默认，不注入模型或思考强度。Claude Code 只展示 `supportedModels()` 明确声明的入口和 effort，创建时由桥校验并传给 SDK；已有 Claude 会话的模型/思考仍只读，不伪称已支持热切换。会话内模型和思考强度使用两个轻量入口。模型弹层提供搜索和按 Agent 过滤的列表；思考弹层只展示当前模型由服务端声明的档位，名称保留英文，不从模型名称猜测能力。Qoder 选中模型时会校验 id 与档位；旧档位不适用时回退到该模型声明的默认档位，目录未声明则不发送。Qoder 会话可为后续轮次切换模型与思考强度，也可恢复 SDK 默认；运行中、离线或正在更新设置时仍可打开查看，修改控件禁用并说明原因。Claude Code 仍只读展示。未读取到模型能力与模型未提供档位分别提示。目录读取失败保留上一次的有效列表，错误只出现在模型控件上，不占用会话横幅。窄窗口下工具栏自动分为两行：主行保留附件、模型/思考与发送，次行放置权限和上下文余量。

旧版桥不打标；客户端此时不过滤、沿用合并列表，所以升级 Mac 客户端不要求同时升级桥。Qoder 模型目录与会话内切换需 native service v10；Claude 模型目录与创建时 effort 需 v11。要使用这些能力需重装桥，并按文末约束等自己的运行中会话结束后再重启托管服务。

环境菜单按具体 Agent 展开配置入口，验证 SSH 后预选对应的 Agent；同一机器的原生 Agent 仍复用一个 SSH/bridge 连接、重连与更新操作。共享连接状态不代表每个 Agent 已登录，登录与模型鉴权分别由对应运行时验证。

组合控件的隔离回归：先运行 `scripts/build.sh`，再运行 `scripts/check-composer-toolbar.sh`。测试在预览 App 内向真实控件发送鼠标和文本编辑事件，覆盖七种 Agent（含两区 Qoder）、Claude 新建任务与已有会话的差异、模型与档位联动、选模型后保持弹层、无档位、九档换行、540 pt 输入区、中英文、离线/运行中/空目录及发送配置；结果保存在 `.local/composer-toolbar-checks/`。不连接真实远端，也不替代真实模型调用或人工视觉验收。预览可独立打开 `build/Composer Toolbar Preview.app`。

## 恢复能力分别处理

| 能力 | 当前边界 |
|---|---|
| 读取工作台创建会话的旧历史 | 已验证：退出 App、重开及托管进程重启后读取；Codex 从原生 `thread/items/list` 重新取回 item |
| 继续工作台创建的旧会话 | 已验证：重启 worker 后，OMP 使用 session path、Qoder 与 Claude 使用 SDK resume ID、dsh 使用 ACP `session/resume`、Codex 使用原生 `thread/resume` 延续上下文 |
| 断开/退出 Mac 时保留运行中任务 | 已验证：OMP 命令在客户端退出后完成；Qoder 待处理请求跨断线保留。dsh 与 Codex 进程由远端托管持有；dsh 的 ACP 会话级断线续跑尚未实测 |
| 接管 Herdr 中运行的会话 | 不支持、不自动尝试，继续使用终端入口 |
| 导入任意既有 CLI 历史 | 本轮未提供导入入口，不把本工作台的恢复能力等同于任意历史兼容 |
| 托管服务或远端主机崩溃后的进行中任务 | 不保证继续执行；下次连接标明任务中断，用户发送新消息后恢复持久上下文，不自动重放旧操作 |

OMP、Qoder、Claude 与 dsh 的归档只属于远端工作台目录，删除工作台会话也保留其上游历史文件。Codex 不做本地模拟：归档、恢复归档和删除分别调用原生 `thread/archive`、`thread/unarchive`、`thread/delete`。运行时不允许归档或删除。停止、失败与正常完成分别处理，主动停止不增加完成计数；之前已有的未查看结果仍可留在待查看队列。

未发送草稿和原生待发队列在 Mac 本地持久化；重启后先核对接收状态，未确认请求不自动重发。OMP/Qoder/dsh 原生附件上传、完整旧 CLI 历史导入、远端主机重启、多客户端同时编辑、长时间休眠与超大历史压力测试不在本轮验收范围，仍可使用终端入口。

## 子 Agent（Claude Code 需 native service v7 起，Codex 需 v9 起）

桥不再丢弃子 Agent 的过程：带 `parent_tool_use_id` 的 assistant / user 消息按主消息同样的 `normalize()` 写进该子 Agent 自己的过程，带父 id 的 `stream_event` 仍然丢弃；主线程的消息、流式尾巴、busy/轮次状态与历史增量保持原样。`task_started / task_progress / task_updated / task_notification` 只处理子 Agent（`task_type` 为 `local_agent`，或没有 `task_type` 但 `tool_use_id` 是 Agent/Task 调用），忽略 `ambient` 与 `skip_transcript`；`background_tasks_changed` 与这些事件的先后未定义，不用来判断结束。别名表把 task id 与 tool use id 映射到条目 key：消息先于 `task_started` 到达时按父 id 建临时条目，描述取主线程 Agent/Task 调用的 `description`（否则 prompt 首行），之后的 `task_started` 并入该条目，key 不变。`pending` 为排队，`paused` 仍算运行，`killed` 为停止；已结束的条目不会被迟到事件复活。从未收到 task 事件的条目由主线程的 tool_result 结束；`agent_end` 或 worker 退出时仍在排队/运行的条目，本轮被停止记为 stopped，否则为 unknown。

- **名单**：会话状态 `subagentRoster` 最多 64 条，超出时删去最旧的已结束条目及其过程文件，不进入深拷贝的快照。快照（全量与增量）带 `subagents`：最新一轮的、仍在排队/运行的、被待处理审批引用的条目，最多 32 条，按 `startedAt` 排序；`GET /sessions` 带 `runningSubagents`，有子 Agent 运行时不替换旧服务。名单、条目与审批标签变化走会话 `touch()`；过程追加只增加该过程自己的 revision，主快照轮询保持安静。
- **过程**：`GET /sessions/<sid>/subagents/<key>`，key 可为条目 id、task id 或 tool use id，未知 key 返回 404。无参数返回最近 200 条（`entry, epoch, revision, total, truncated, start, messages`）；`?epoch&revision` 同 revision 返回 `{"unchanged":true}`，否则返回 `changes:[{index,message}]`，epoch 不同返回全量；`?epoch&before&limit`（limit ≤ 200，默认 100）取更早一页，epoch 过期时与主会话的 `before` 一样返回 400。
- **持久化与上限**：过程写在 `subagents/<sid>/<key>.json`（epoch、revision、truncated、messages、versions），约 2 秒防抖，条目结束与 `agent_end` 时立即写；首次读取才载入；随会话删除。内存只保留排队/运行中条目的过程，以及每会话最近读过的至多 8 份已结束过程，换出前先写盘，本服务换出后再载入沿用原 epoch；上一个服务写下的文件可能落后于客户端已读内容，载入后换新 epoch。服务启动时排队/运行中的条目改为 unknown，并清除不属于任何会话或条目的文件。每份过程最多 2,000 条或约 4 MiB，超出后从头裁到 75%，换新 epoch 并累计 `truncated`；单段文本、思考、工具输出与工具输入里的每个字符串最多 32 KiB，截断处带标记；截断后仍超过裁剪目标（预算的 75%）的单条消息改为一条省略提示，裁剪因此总能达标。
- **停止**：`POST /sessions/<sid>/subagents/<key>/stop` 仅在条目 `canStop`（Claude、排队或运行中、已知 task id、会话有活动轮次）时向 worker 发 `{type:'stop_task', taskId, turnId}`，记 `stopRequested`，否则 400。worker 只对当前轮调用 SDK `stopTask`，回 `task_stop_result`；失败时 `stopError` 带原因，可重试。0.3.280 在最后一个后台子 Agent 结束后的追加轮里可能停止失败，此时改用整轮停止。
- **审批**：worker 给审批带上 `context.agentID`；桥经别名表或子 Agent 过程中已出现的被审批 tool_use id 解析成 `subagent:{id, agentId, title, type}`，暂时解析不到时 `id` 为 null，之后的事件对上时补全。主线程审批不带该字段。
- **文字转发**：`forwardSubagentText` 由桥常量 `CLAUDE_FORWARD_SUBAGENT_TEXT` 传入 worker，默认开启，过程里有子 Agent 的文字、思考与工具调用。
  2026-10-18 实测（SDK 0.3.280、CLI 2.1.302）：子 Agent 的 assistant/user 消息都带 `parent_tool_use_id`，无父 id 的流式 delta 中没有子 Agent 独有的文字，
  主线程的流式尾巴不受影响。若新版 CLI 改变这一点，把常量改回 `False`，过程退回只有工具调用与结果。

### Codex 子线程（native service v9）

名单、过程路由、持久化与上限同上；条目 `kind` 为 `codex`，key 是子线程 threadId（`taskId` 同值）。
2026-10-19 实测（codex-cli 0.162.1，产出在 `_evidence/perch-subagents-20261018/probe/codex-20261019/`）：子线程的帧送到父线程的同一条连接，带子线程自己的 threadId（thread/status/changed、mcpServer/startupStatus/updated、turn/started、turn/moderationMetadata、item/started|completed、hook/*、thread/tokenUsage/updated、item/agentMessage/delta、turn/completed）；父线程用 `subAgentActivity` 条目宣布子线程：`kind: started`（带 agentThreadId、agentPath 如 `/root/list_files`、model）在 item/started 与 item/completed 各出现一次，子线程结束后另有 `id: subagent-completed-<子线程轮次>` 的 `kind: completed`。没有子线程的 `thread/started`，也没有 spawnAgent 的 `collabAgentToolCall`（只有一次 receivers 为空的 `wait`；其他配置会发 spawnAgent 及 receiverThreadIds、agentsStates）。`thread/items/list {threadId: 子线程, sortDirection: "asc", limit: 100}` 读到了子线程的 agentMessage 与 commandExecution。子线程审批未触发；上游 v2 子线程接受 `turn/interrupt {threadId, turnId}`，拒绝 turn/start 与 turn/steer。

- **登记**：四个来源。父线程（或已登记子线程）的 `subAgentActivity`：`started` 条目的 id 进 `toolUseIds`，描述取 agentPath 末段，`subagentType` 为 agentPath，另记模型与时间；interrupted 记停止，completed 记完成。`collabAgentToolCall` 的 receivers 与 agentsStates：pendingInit 为排队，running 运行，errored 失败，interrupted 停止，completed 与 shutdown 完成，notFound 为 unknown；spawnAgent 调用的 id 进 `toolUseIds`，描述取 prompt 首行。父线程为本会话或已登记子线程的 `thread/started`：描述取 agentNickname，类型取 agentRole。恢复会话时 `thread/items/list` 历史里的同样条目：app-server 已换新，历史里看似仍在运行的子线程记 unknown。运行态只描述新建的条目，结束态结束运行中或 unknown 的条目；已结束的条目只在子线程自己开始新一轮（父线程给它发了新输入）时重新运行，并清掉上一轮的错误。
- **主线程卡片**：`subAgentActivity` started 在父线程过程里显示为 `agent/spawnAgent` 工具调用（id 即该条目 id，输入 `{agentPath, model}`），App 的「查看过程」经 `toolUseIds` 打开对应子线程；子线程完成、停止或失败时以其 summary（没有时用状态文字）作为调用结果。孙线程的卡片在子线程自己的过程里。
- **路由**：已登记子线程的 item/started|completed 经可指定写入目标的 `codex_item` 写进它自己的过程，只取完整条目，不跟随增量、hook 与状态帧。`turn/started` 记子线程自己的轮次：Codex 条目的 `turnId` 是子线程的轮次，所属主轮次另存（取上报它的主线程帧，或子线程轮次的 rootTurnId），快照的「最新一轮」按主轮次判断。`turn/completed` 记结束状态、summary（该轮最后一条 agentMessage）与累加的 `durationMs`，每轮只计一次，并只清该子线程的审批；`thread/tokenUsage/updated` 的 total 记为该子线程的用量。尚未登记的 threadId 的这几类帧最多缓冲 256 条、30 秒，登记后按序重放，过期丢弃。主线程的处理与此前逐字节一致。
- **审批**：已登记子线程的反向请求作为带 `subagent:{id, agentId, title, type}` 的审批上报，走原有回答路径；主线程 `turn/completed` 只清主线程的审批，子线程的审批随它自己的 `turn/completed` 或 `serverRequest/resolved` 清除；未登记 threadId 的请求仍回 -32602。app-server 退出时清空全部审批，仍在运行的子线程记 unknown。
- **停止**：`canStop` 为 Codex 条目、运行中、已知子线程轮次，与主轮次是否仍在运行无关（子线程可以比主轮次活得久）。停止路由发 `turn/interrupt {threadId: 子线程, turnId: 子线程轮次}` 并记 `stopRequested`，之后子线程 interrupted 的 `turn/completed` 记为停止；app-server 拒绝或已退出时返回 400 与原因，不记 `stopRequested`。
- **补历史**：读取过程时若 Codex 条目的过程缺失或为空，在会话锁外用 `thread/items/list`（asc，每页 100，最多 200 页）读该子线程，保留最新的 2,000 条再写入过程。会话的 app-server 在运行时用它，否则与模型目录一样临时启动一个、读完即关。成功读过一次就不再读；失败后 30 秒内不重试；读取期间已由实时帧填入的过程以实时帧为准。

## 运行中引导

OMP 运行中使用 `steer` RPC，Codex 使用 `turn/steer`；菜单都可改选“下一轮发送”。需要同步更新 Mac 客户端和远端桥接脚本；客户端仅在服务端会话声明 `steer` 能力时提供引导。Qoder CN / Qoder / dsh / Claude Code 继续使用下一轮队列。

消息发送后在会话正文显示完整文字和状态。RPC 确认只表示已接收；观察到运行时的 user message 回显后才合并到历史。引导不会替换当前 turnId，停止仍针对当前任务。失败或未确认的消息保持可见，不自动重放。

更新桥接文件后，已运行的服务仍是旧代码；下一次检查会读取会话状态，仅在没有运行中任务、待审批请求和异步命令时自动替换旧服务，不会为了升级中断已有任务。

## 接入检查

向导通过经鉴权的 `GET /setup?provider=omp|qoder|qoderintl|dsh|codex|claude` 检查所选运行时；
不会因为缺少未选 Agent 而报错。检查在会话锁之外执行，不向模型发送消息。
OMP 每次重新读取模型配置，只返回名称、provider 和 id，不返回 headers 或密钥。
Qoder CN 与 Qoder 的检查分别启动对应 SDK daemon 并实时调用 `accountInfo()` 取得 userId 后调用 `getModels({ fetchStrategy: "live", uid })`；成功返回脱敏目录即确认该区 CLI 登录，不发送 prompt，也不读取另一地区目录。Claude 通过 SDK `supportedModels()` 实时读取脱敏目录，不发送 prompt；SDK 没有独立登录检查接口，仍由首条消息验证鉴权。dsh 只检查桥接进程是否具有
`DEEPSEEK_API_KEY`，不读取或返回值，模型在首次 ACP 会话握手时读取。Codex 使用所选
HOME 的 app-server `account/read` 检查鉴权模式：官方供应商需要已有账号；不要求 OpenAI
登录的供应商返回 `provider-managed`，界面明确提示实际鉴权在首条消息时验证。随后通过
`model/list` 读取脱敏的模型 id 与名称，不发送 turn，不返回账号信息或密钥。

### Codex 专用配置目录

默认沿用桥进程原有的 `CODEX_HOME`，未设置时使用 `~/.codex`。如需让 Perch 的新 Codex
会话使用第三方供应商，可在远端 `~/.local/share/agent-workbench/native/codex-home` 写入
专用目录的绝对路径（也接受 `~/` 前缀），例如 `~/.codex-provider`。文件只保存路径，不保存
密钥；在该目录的 `config.toml` 中按 Codex 官方配置供应商、环境变量或认证命令。

创建会话时固定 HOME，目录缓存也按 HOME 隔离。修改或移除路径文件只影响之后的新会话；
已有会话恢复、模型和思考档位校验仍使用创建时的 HOME。升级前的会话保留原 HOME，不自动
迁入专用目录。不要重写旧 HOME 的供应商定义，也不要用强行覆盖 HOME 的 CLI wrapper 改变
已有线程身份。原终端 `codex` 的配置与登录不受路径文件影响。

供应商若只提供标准 OpenAI `/models` 列表而非 Codex 目录，使用 Codex 的
`model_catalog_json` 指定对应模型的完整目录；能力和思考档位必须有依据，不从模型名称猜测。
第三方供应商的接入向导需要同步更新 Mac 客户端，以识别 `provider-managed` 状态。

旧服务返回“未知路径”时先更新组件并重新检查；检查会在服务空闲时自动完成重启，
有活动任务时明确提示等待，安装器本身不会终止旧服务。新建任务中的空模型沿用运行时默认值，不再注入固定的 Qoder 模型。

## 权限模式

设置 → 新会话默认权限可分别配置 Kimi、OMP、Qoder CN、Qoder、Codex 与 Claude Code；新建任务时仍可覆盖，修改默认值不会改变已有会话。输入框旁会显示当前模式和生效范围：Kimi 可为下一条消息切换，Qoder CN、Qoder 与 Claude Code 可为下一轮切换；OMP 与 Codex 在创建时固定，只读展示。dsh 不伪造全局权限模式，继续使用 ACP 运行时审批卡片逐次确认。

| Agent | 模式（粗体为安全默认） | 传递方式 | 生效范围 |
|---|---|---|---|
| Kimi | **`manual`** / `yolo` / `auto` | prompt body 的 `permission_mode` | 下一条消息 |
| OMP | **`always-ask`** / `write` / `yolo` | `omp --approval-mode` | 创建会话时固定 |
| Qoder CN | **`default`** / `acceptEdits` / `plan` / `dontAsk` / `auto` / `bypassPermissions` | 每次 SDK `query` 的 `permissionMode` | 下一轮 |
| Qoder | **`default`** / `acceptEdits` / `plan` / `dontAsk` / `auto` / `bypassPermissions` | 每次 SDK `query` 的 `permissionMode` | 下一轮 |
| dsh | runtime-managed | ACP `session/request_permission` | 每次请求 |
| Codex | `read-only` / **`workspace-ask`** / `workspace-auto` / `full-access` | app-server 参数，见下表 | 创建会话时固定 |
| Claude Code | **`default`** / `acceptEdits` / `plan` / `bypassPermissions` | 每次 SDK `query` 的 `permissionMode` | 下一轮 |

Kimi 的历史会话若没有可识别的权限字段，界面显示“沿用会话设置”，发送时不注入值；用户主动选择后才覆盖。Qoder 与 Claude 的 `bypassPermissions` 同时传 `allowDangerouslySkipPermissions: true`。Kimi `auto`、OMP `yolo`、Qoder 与 Claude 的 `bypassPermissions` 和 Codex `full-access` 属于高风险模式，选择时需再次确认；其他较宽松模式以橙色提示，但不额外弹窗。

Codex 的 reviewer 始终为 `user`，四档映射如下：

| 模式 | `approvalPolicy` | `approvalsReviewer` | thread `sandbox` | turn `sandboxPolicy.type` |
|---|---|---|---|---|
| `read-only` | `on-request` | `user` | `read-only` | `readOnly` |
| `workspace-ask`（默认） | `on-request` | `user` | `workspace-write` | `workspaceWrite` |
| `workspace-auto` | `never` | `user` | `workspace-write` | `workspaceWrite` |
| `full-access` | `never` | `user` | `danger-full-access` | `dangerFullAccess` |

Perch 不修改远端 `config.toml`，也不会在恢复时放宽会话权限。旧 Codex 默认值 `ask`、`auto-review` 安全迁移为 `workspace-ask`，`full-access` 保留。管理策略或运行时不接受所选权限时，错误仍通过任务错误通道展示，不自动降级或放宽。

权限字段及 Codex 参数已对照当前运行时协议；Codex 权限需 native service v3 起，Claude Code 附件需 v5 起，Codex 附件需 v6 起，Claude Code 子 Agent 需 v7 起，Claude Agent SDK 0.3.302 需 v8 起，Codex 子线程需 v9 起，Qoder 双区模型目录与切换需 v10 起，Claude 模型目录与创建时 effort 需 v11 起，服务升级应等待活跃任务结束。Codex 官方语义见 [Sandbox](https://learn.chatgpt.com/docs/sandboxing)。
