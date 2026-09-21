# OMP / Qoder CN / DeepSeek 原生对话

Mac 界面、远端执行。⌘N 选择 Kimi、OMP、Qoder CN 或 DeepSeek，默认沿用当前目录，也可选择最近目录；名称由第一条消息生成，自动关联当前任务组。置顶、分组、待处理队列与工作现场共用，顶部不恢复重复标签栏。

## 已核对的运行时

- OMP 18.1.16：先验证 `--mode rpc` 的消息流和审批，再使用同协议的 `--mode rpc-ui` 启用内置 `ask` 工具。启动时显式使用 `--approval-mode always-ask`，不启用 yolo。接收 message 事件、工具调用/结果及 extension UI 请求；协商 v2，按帧序号与字节数校验分块。
- Qoder CN：官方 `@qodercn-ai/qodercn-agent-sdk` 1.0.45，发行包 runtime-manifest 明确匹配 CLI 1.1.58。通过 SDK `query`、`canUseTool`、`interrupt` 和 `resume` 接入已安装的 `qoderclicn`，未使用 ACP 推断兼容性。沿用远端 CLI 登录，权限模式为 default；需确认的调用由 Mac 界面返回本次 allow/deny。
- DeepSeek Harness（dsh）0.1.5-rc.1：走标准 ACP v1（`dsh --profile acp`，stdio JSON-RPC）。已实测 `initialize`、`session/new|list|resume`、`session/set_config_option`（model 与 reasoning_effort）以及无凭据时 `session/prompt` 的报错路径；`session/cancel` 与 `session/request_permission` 按官方 ACP 契约接入。每会话一个进程，握手完成后才放行 prompt；dsh 只发已提交的消息块（无增量流），审批以 select 卡片呈现，选项标签映射回不透明 optionId。dsh 是 developer preview，升级版本必须重跑协议核对。

参考：[OMP 18.1.16 RPC 文档](https://github.com/can1357/oh-my-pi/blob/v18.1.16/docs/rpc.md)、[Qoder CN 官方 SDK](https://docs.qoder.cn/cli/sdk/overview)、[dsh ACP 包说明](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/acp/acp)。

## 远端托管

`remote/native-agent-service.py` 是仅监听远端 127.0.0.1 的独立进程，通过系统 SSH 隧道访问；持有 OMP 的 stdin/stdout、Qoder SDK worker 与 dsh 的 ACP 进程。Mac 断线、退出不关闭这些管道，因此 Agent、工具及待审批请求继续存在。远端使用随机访问令牌，目录/文件限定当前用户访问，Mac 只在内存持有令牌。

远端安装位置：`~/.local/share/agent-workbench/native`。会话目录保存工作台转译后的消息、状态和上游 resume 标识；不会保存 OMP get_state 中的模型 headers、认证配置。SDK 使用独立 npm 目录，不替换全局 CLI。dsh 会话使用独立的 `DSH_HOME`（托管目录下 `dsh-home/`），不读写用户的 `~/.dsh`；遥测显式 `DSH_TELEMETRY_MODE=DISABLED`；模型凭据沿用远端 `DEEPSEEK_API_KEY` 环境变量，桥不接触。

```sh
./scripts/install-native-service.sh dev-env
# 追加 dsh 运行时（钉版 deepseek-harness-sdk，自带单文件运行时，目标机无需 Node）：
./scripts/install-native-service.sh dev-env --with-dsh
```

目标需 Python 3、Node.js 18+、已登录的 qoderclicn 1.1.58 与 omp 18.1.16。安装脚本禁用 npm 生命周期脚本，SDK 明确使用现有 CLI。Mac 连接时启动或复用托管服务。更新脚本不会杀死运行中的托管服务；更新运行中的服务前，先等待自己的会话安全结束。

Mac 当前每 400 ms 查询轻量目录和选中对话的 revision；未变化时不传输或重建整段历史。只在会话元数据变化时更新全局队列，流式内容局限于原生对话视图。正文、Markdown、工具卡片和按轮折叠的执行过程与 Kimi 共用。

## 恢复能力分别处理

| 能力 | 当前边界 |
|---|---|
| 读取工作台创建会话的旧历史 | 已验证：退出 App、重开及托管进程重启后读取 |
| 继续工作台创建的旧会话 | 已验证：重启 worker 后，OMP 使用 session path、Qoder 使用 SDK resume ID、dsh 使用 ACP `session/resume` 延续上下文 |
| 断开/退出 Mac 时保留运行中任务 | 已验证：OMP 命令在客户端退出后完成；Qoder 待处理请求跨断线保留。dsh 进程由托管持有，但 ACP 会话级的断线续跑尚未实测 |
| 接管 Herdr 中运行的会话 | 不支持、不自动尝试，继续使用终端入口 |
| 导入任意既有 CLI 历史 | 本轮未提供导入入口，不把本工作台的恢复能力等同于任意历史兼容 |
| 托管服务或远端主机崩溃后的进行中任务 | 不保证继续执行；下次连接标明任务中断，用户发送新消息后恢复持久上下文，不自动重放旧操作 |

原生 Agent 归档属于远端工作台目录，不删除上游历史；删除工作台会话同样保留 OMP / Qoder 自身的历史文件。运行时不允许归档/删除。停止、失败与正常完成分别处理，主动停止不增加完成计数；之前已有的未查看结果仍可留在待查看队列。

未发送草稿仅在 Mac 当前进程保存。OMP/Qoder 原生附件上传、完整旧 CLI 历史导入、远端主机重启、多客户端同时编辑、长时间休眠与超大历史压力测试不在本轮验收范围，仍可使用终端入口。
