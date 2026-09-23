# OMP / Qoder CN / DeepSeek / Codex / Claude Code 原生对话

Mac 界面、远端执行。⌘N 选择 Kimi、OMP、Qoder CN、DeepSeek、Codex 或 Claude Code，默认沿用当前目录，也可选择最近目录；名称由第一条消息生成，自动关联当前任务组。置顶、分组、待处理队列与工作现场共用，顶部不恢复重复标签栏。

## 已核对的运行时

- OMP 18.1.16：先验证 `--mode rpc` 的消息流和审批，再使用同协议的 `--mode rpc-ui` 启用内置 `ask` 工具。创建会话时把所选 `always-ask`、`write` 或 `yolo` 显式传给 `--approval-mode`；会话内不动态切换。接收 message 事件、工具调用/结果及 extension UI 请求；协商 v2，按帧序号与字节数校验分块。
- Qoder CN：官方 `@qodercn-ai/qodercn-agent-sdk` 1.0.45，发行包 runtime-manifest 明确匹配 CLI 1.1.58。通过 SDK `query`、`canUseTool`、`interrupt` 和 `resume` 接入已安装的 `qoderclicn`，未使用 ACP 推断兼容性。沿用远端 CLI 登录；每次 `query` 带当前权限模式，切换从下一轮生效。需确认的调用由 Mac 界面返回本次 allow/deny；`bypassPermissions` 还会显式设置 `allowDangerouslySkipPermissions`。
- DeepSeek Harness（dsh）0.1.5-rc.1：走标准 ACP v1（`dsh --profile acp`，stdio JSON-RPC）。已实测 `initialize`、`session/new|list|resume`、`session/set_config_option`（model 与 reasoning_effort）以及无凭据时 `session/prompt` 的报错路径；`session/cancel` 与 `session/request_permission` 按官方 ACP 契约接入。每会话一个进程，握手完成后才放行 prompt；dsh 只发已提交的消息块（无增量流），审批以 select 卡片呈现，选项标签映射回不透明 optionId。dsh 是 developer preview，升级版本必须重跑协议核对。
- Codex CLI 0.155.1：按本机 `app-server generate-json-schema --experimental` 生成的完整 schema 核对协议，并实机验证创建、无工具 turn、恢复、归档、恢复归档与删除。只使用 `codex app-server --listen stdio://` 的 JSON-RPC，不启动 PTY，也不抓取终端画面。创建与恢复分别调用 `thread/start`、`thread/resume`，Perch 会话 ID 就是原生 thread UUID；历史通过 `thread/items/list` 恢复。发送、运行中引导和停止分别使用 `turn/start`、`turn/steer`、`turn/interrupt`。流式正文、思考、计划、工具和 token usage 转入统一对话；完成 item 覆盖增量草稿。模型及 reasoning effort 来自 `model/list`，创建和切换时均拒绝目录之外的值，切换仅用于后续 turn。command、file change、permissions、tool input 与 MCP elicitation 等 app-server 反向请求全部显示在 Mac 上并等待明确回答，不自动批准或静默拒绝。
- Claude Code：官方 `@anthropic-ai/claude-agent-sdk` 0.3.280，驱动远端已安装并登录的 `claude` CLI（2.1.280）。消息类型与 Qoder SDK 同构（system init / assistant / user / stream_event / result），桥与 Mac 复用同一 worker 事件协议：SDK `query`、`canUseTool`、`interrupt`、`resume`。沿用远端 CLI 登录与凭据，桥不接触；每次 `query` 带当前权限模式，切换从下一轮生效；`bypassPermissions` 同时显式设置 `allowDangerouslySkipPermissions`。SDK 不提供模型清单，留空使用 CLI 默认模型。

参考：[OMP 18.1.16 RPC 文档](https://github.com/can1357/oh-my-pi/blob/v18.1.16/docs/rpc.md)、[Qoder CN 官方 SDK](https://docs.qoder.cn/cli/sdk/overview)、[dsh ACP 包说明](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/acp/acp)、[Codex app-server](https://github.com/openai/codex/tree/main/codex-rs/app-server)、[Claude Agent SDK](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk)。

## 远端托管

`remote/native-agent-service.py` 是仅监听远端 127.0.0.1 的独立进程，通过系统 SSH 隧道访问；持有 OMP 的 stdin/stdout、Qoder 与 Claude 的 SDK worker、dsh 的 ACP 进程与 Codex app-server。Mac 断线、退出不关闭这些管道，因此 Agent、工具及待审批请求继续存在。远端使用随机访问令牌，目录/文件限定当前用户访问，Mac 只在内存持有令牌。

远端安装位置：`~/.local/share/agent-workbench/native`。会话目录保存工作台转译后的消息、状态和上游 resume 标识；不会保存 OMP get_state 中的模型 headers、认证配置。Codex 身份与凭据仍由远端已登录的 `codex` CLI 管理，桥只保存 thread UUID。SDK 使用独立 npm 目录，不替换全局 CLI。dsh 会话使用独立的 `DSH_HOME`（托管目录下 `dsh-home/`），不读写用户的 `~/.dsh`；遥测显式 `DSH_TELEMETRY_MODE=DISABLED`；模型凭据沿用远端 `DEEPSEEK_API_KEY` 环境变量，桥不接触。

```sh
# App 内可直接点击「安装 / 更新桥接组件」，也可显式指定机器与 Agent：
./scripts/install-native-service.sh my-server --provider=omp
./scripts/install-native-service.sh my-server --provider=qoder
./scripts/install-native-service.sh my-server --provider=dsh
./scripts/install-native-service.sh my-server --provider=codex
./scripts/install-native-service.sh my-server --provider=claude
# 保留旧的全套安装方式：<host> 或 <host> --with-dsh
```

所有桥接目标需 Python 3。OMP 使用已配置的 omp 18.1.16，不要求 npm；Qoder 使用 Node.js/npm 与已登录的 qoderclicn 1.1.58；Claude Code 使用 Node.js/npm 与已登录的 `claude` CLI；dsh 安装固定版本的 Python SDK wheel，不要求 Node.js；Codex 使用已安装且登录可用的 `codex` CLI，不要求桥接安装器运行 npm。安装脚本禁用 npm 生命周期脚本，SDK 明确使用现有 CLI。Mac 连接时启动或复用托管服务。安装或更新文件本身不会终止托管服务；后续检查会验证协议版本，在所有会话空闲时自动替换旧服务，存在运行中任务、待审批请求或异步命令时保留旧服务并提示等待。

Mac 当前每 400 ms 查询轻量目录和选中对话的 revision；未变化时不传输或重建整段历史。只在会话元数据变化时更新全局队列，流式内容局限于原生对话视图。正文、Markdown 和按发生顺序展示的工具摘要与 Kimi 共用；工具完成后仍保留摘要，仅参数和输出按需展开。

## 模型选择

桥的 `/models` 是合并目录，每条带 `agent` 字段说明谁能路由它：OMP 来自 `omp models --json`（18.1.16 输出 `{"models":[...]}` 包装，桥负责展开），dsh 来自 ACP config options（首次握手后缓存到 `dsh-catalog.json`）。Mac 端按当前 Agent 过滤，因此 OMP 不会被提供 dsh 的路由，反之亦然。

新建任务面板里 Kimi、OMP、dsh 共用同一个可搜索下拉；模型输入框保留，既显示将要发送的 id，也接受目录里没有的 id（`omp models --no-extensions` 不含扩展提供的模型）。Qoder CN 与 Claude Code 的 SDK 不提供模型清单，因此只有输入框：Qoder 留空即 `Qwen3.8-Flash`，Claude Code 留空使用远端 CLI 默认模型。会话内的模型菜单与思考强度同样按 Agent 过滤，运行中不可切换；Qoder 只显示标签。目录读取失败保留上一次的有效列表，错误只出现在模型控件上，不占用会话横幅。

旧版桥不打标；客户端此时不过滤、沿用合并列表，所以升级 Mac 客户端不要求同时升级桥。要拿到按 Agent 过滤的目录需重装桥，并按文末约束等自己的运行中会话结束后再重启托管服务。

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

未发送草稿仅在 Mac 当前进程保存。OMP/Qoder/Codex/Claude 原生附件上传、完整旧 CLI 历史导入、远端主机重启、多客户端同时编辑、长时间休眠与超大历史压力测试不在本轮验收范围，仍可使用终端入口。

## 运行中引导

OMP 运行中使用 `steer` RPC，Codex 使用 `turn/steer`；菜单都可改选“下一轮发送”。需要同步更新 Mac 客户端和远端桥接脚本；客户端仅在服务端会话声明 `steer` 能力时提供引导。Qoder CN / dsh / Claude Code 继续使用下一轮队列。

消息发送后在会话正文显示完整文字和状态。RPC 确认只表示已接收；观察到运行时的 user message 回显后才合并到历史。引导不会替换当前 turnId，停止仍针对当前任务。失败或未确认的消息保持可见，不自动重放。

更新桥接文件后，已运行的服务仍是旧代码；下一次检查会读取会话状态，仅在没有运行中任务、待审批请求和异步命令时自动替换旧服务，不会为了升级中断已有任务。

## 接入检查

向导通过经鉴权的 `GET /setup?provider=omp|qoder|dsh|codex|claude` 检查所选运行时；
不会因为缺少未选 Agent 而报错。检查在会话锁之外执行，不向模型发送消息。
OMP 每次重新读取模型配置，只返回名称、provider 和 id，不返回 headers 或密钥。
Qoder 与 Claude 的 SDK 没有独立登录检查接口，首条消息验证鉴权；dsh 只检查桥接进程是否具有
`DEEPSEEK_API_KEY`，不读取或返回值，模型在首次 ACP 会话握手时读取。Codex 使用
`codex login status` 检查登录，只返回是否可用；登录后从 app-server `model/list`
读取脱敏的模型 id 与名称，不发送 turn。

旧服务返回“未知路径”时先更新组件并重新检查；检查会在服务空闲时自动完成重启，
有活动任务时明确提示等待，安装器本身不会终止旧服务。新建任务中的空模型沿用运行时默认值，不再注入固定的 Qoder 模型。

## 权限模式

设置 → 新会话默认权限可分别配置 Kimi、OMP、Qoder CN、Codex 与 Claude Code；新建任务时仍可覆盖，修改默认值不会改变已有会话。输入框旁会显示当前模式和生效范围：Kimi 可为下一条消息切换，Qoder 与 Claude Code 可为下一轮切换；OMP 与 Codex 在创建时固定，只读展示。dsh 不伪造全局权限模式，继续使用 ACP 运行时审批卡片逐次确认。

| Agent | 模式（粗体为安全默认） | 传递方式 | 生效范围 |
|---|---|---|---|
| Kimi | **`manual`** / `yolo` / `auto` | prompt body 的 `permission_mode` | 下一条消息 |
| OMP | **`always-ask`** / `write` / `yolo` | `omp --approval-mode` | 创建会话时固定 |
| Qoder CN | **`default`** / `acceptEdits` / `plan` / `dontAsk` / `auto` / `bypassPermissions` | 每次 SDK `query` 的 `permissionMode` | 下一轮 |
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

权限字段及 Codex 参数已对照当前运行时协议；需要更新到 native service v3 后使用，服务升级应等待活跃任务结束。Codex 官方语义见 [Sandbox](https://learn.chatgpt.com/docs/sandboxing)。
