# 后续恢复调用注意事项

- 本轮已按停止规则②停止；这里是恢复指针，不是已排队的新作业。
- 每次新截图构建传新的 `--host-app` 路径。`--build-host` 会调用 `--build-only`，不能同时复用已编译 app。
- 复用已有 app 时不传 `--build-host`；保留旧 app 和证据，不删除来绕过参数契约。
- 用已验证的 PerfRunner Aqua 队列和 Node screenshot helper；不改 TCC、runner、权限或 SSH 配置。
- `PerchSourceRevision` 是 `git describe --tags --dirty --always`，不是完整 Git SHA。
  Git 代码头由作业 `code_head` 与 capture manifest 单独记录，不能混用两种身份。
- portable schema 是 `.status` 与 `.checks[]`，不是 `.passed` / `.results[]`。
- 本轮 build、WorkbenchChecks、portable 10 项和 5 次冷启动已完成，native-design 未执行。
  若后续只补 native-design，应复用候选已编译 host 并单独归档，不重跑完成步骤。
- 所有恢复步骤先核对 INDEX、停止原因、实际分支头与结果；不得自动重启 S02/S03。
