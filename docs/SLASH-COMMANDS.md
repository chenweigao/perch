# 对话输入框命令

输入 `/` 查看当前入口的命令，↑↓ 选择、Tab 补全、Esc 收起。完整命令可直接 Return 执行；未写完整时 Return 补全当前候选。Shift-Return 换行，目标正文可以包含多行。

## Kimi

| 命令 | 行为 |
| --- | --- |
| `/goal <目标正文>` | 创建目标，再发送正文启动首轮；不更改现有审批权限 |
| `/goal` 或 `/goal status` | 查询目标、状态、轮数和 token 使用量 |
| `/goal pause` | 暂停后续目标续跑 |
| `/goal resume` | 请求服务端恢复目标，由服务端启动续跑，不额外发送第二条消息 |
| `/goal cancel` | 移除目标 |
| `/compact [保留要求]` | 请求压缩上下文，可说明需要保留的信息 |
| `/plan on`、`/plan off` | 显式开启或关闭计划模式 |
| `/help` | 显示上述命令 |

例如：

```text
/goal 修复会话历史滚动卡顿，保留完整消息，验证阅读位置不跳动
/compact 保留已验证的结论、未完成事项和相关文件路径
```

以保留字开头的目标使用 `/goal -- <正文>`。此入口不提供 `replace`、`next`；会提示保留原草稿，不会将它们误当成新目标。

压缩、开始/恢复目标及切换计划模式要求会话空闲。暂停或取消目标不会在客户端自动中断当前轮次；如需立即中断，使用已有的停止按钮。携带附件的命令会提示先移除附件。

命令请求成功后才清空原草稿，不覆盖等待期间新输入的内容。若目标已经创建，但首条消息发送失败或结果未知，输入框保留目标正文，并提示先检查会话；不会自动再次创建目标或重放消息。HTTP 接收压缩请求不表示压缩已完成。

## 原生 Agent

命令列表仍以运行时上报为准。当前桥接支持 OMP 的无参数 `/compact`；其他命令的执行能力没有因补全面板而扩大。

OMP 18.1.16 的 `/goal` 仅有 TUI handler，没有 RPC/text handler，因此不在 RPC 可用命令列表中。手动输入 `/goal` 会保留草稿并提示使用终端或 Kimi；不会作为普通提示词交给模型。Qoder/dsh 未开放目标命令时同样如此。

## 协议与验证边界

Kimi 映射依据 0.43.0 的 KAP 路由与协议：`GET /sessions/{id}/goal`、`POST /sessions/{id}/profile` 的 `agent_config`，以及 `POST /sessions/{id}:compact` 的 `instruction`。创建目标后另走已有的 `/prompts` 发送链；恢复目标的 profile 路由本身负责启动续跑。

OMP 边界依据 [18.1.16 RPC 文档](https://github.com/can1357/oh-my-pi/blob/v18.1.16/docs/rpc.md) 及该版本 `builtin-modes.ts`、`available-commands.ts` 的 handler 筛选。

核心解析与 HTTP 路由、草稿、会话隔离有回归检查。Linux 执行使用独立平台适配副本；macOS AppKit 键盘交互与真实 Kimi 服务的目标续跑仍需现场验收。
