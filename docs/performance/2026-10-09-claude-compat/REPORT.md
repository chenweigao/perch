# Claude 会话边界与正文兼容修复

## 已确认的问题

对用户指定的连接测试会话做了只读检查。未启动新模型请求、修改会话、升级或重启远端服务。检查时远端 SDK 为 0.3.280，原始 Claude 日志记录 CLI 2.1.295；本地修复基于 main `d7da66f`。

- 某次快照包含 4 条真实用户输入、104 条 user-role 工具结果、2 条 skill 注入。其中一条 skill 正文为 103,806 字符。旧的 `isUserPrompt` 把工具结果和这类 skill 文本也算作用户输入，影响分页、轮次导航、当前轮活动统计及工具结果归属。
- Claude 原始记录的 skill 注入带有 `isMeta`；SDK 使用 `isSynthetic` 表达合成消息。桥接仅取内层 message，丢失外层来源，导致 skill 内容作为普通正文排版。已有快照也没有该来源字段。
- 按 UUID 对照，检查时至少 217 条桥接消息来自该会话的子任务日志。桥接把它们当作主任务消息，还会清除正在显示的主任务 partial。这里是来源匹配，不是推测正文语义。
- Claude 的完整 assistant 消息按内容块到达，块索引继续递增。旧桥接在提交一个块后清空 partial，但后续 delta 仍用 API 块索引访问新的单元素数组；第二块以后的文本因而可能不更新。该问题由合成事件顺序复现，未声称从远端完整 token 轨迹测得。

用户的会话原文、技能正文、项目内容与完整原始日志未加入仓库。

## 改动

1. Swift 与 Python 使用一致的轮次分类：纯工具结果及运行上下文不建立新轮次；含真实文本的混合用户消息仍保留轮次。
2. 保留 Claude 合成文本的 `source.kind=runtime_context`。对丢失来源的历史 skill 快照，识别已观察到的 `Base directory for this skill: …` 多行格式，复用现有按需展开的运行上下文展示；不删除内容。
3. 有 `parent_tool_use_id` 的 Claude assistant/user/stream 事件不进入主正文，也不清除主任务 partial 或触发其 revision。主任务的 Agent 工具调用、最终工具结果与交互审批继续保留。子任务逐条过程未来需要独立展示，不应混入主对话。
4. Claude 的流式块单独跟踪 API index，每个完整块按自己的 UUID 提交；后续块继续增量显示。Qoder 保留原来的处理路径。

事件顺序与来源字段同时核对了部署 SDK 的类型定义及 [Claude 官方流式文档](https://code.claude.com/docs/en/agent-sdk/streaming-output)。

## 验证

- 旧/新桥接对照：4 个真实输入 + 104 个工具结果 + 1 个 skill 注入，轮次索引从 **109 → 4**；一轮分页从 skill 注入开头恢复为真正用户输入；第二内容块从空字符串恢复为增量文本；子任务不再增加主任务 revision 或清除主任务流。
- 110 项离线桥接测试、WorkbenchChecks、22 项性能工具测试通过。
- 新增 `claude` UI 夹具：4 轮、104 个工具结果、136,047 字符的合成 skill。五次跨轮跳转准确，正文没有挂载 skill 正文，没有可见缺行，折叠后的文档高度为 2,978pt。该检查已接入 macOS functional CI。
- 现有 200 轮导航、完整阅读及交互回归通过。
- 独立 Release 生产构建及严格签名验证通过。可选 live SSH 检查未配置，跳过。UI 夹具在生产构建期间运行，其耗时不作为性能结果。

来源哈希、对照输出和 UI 回执见 `validation.json`；提交前构建以源码哈希识别具体候选，不能把回执中的基线 commit 当成干净候选提交。

## 尚未证明 / 上线边界

这轮消除了错误轮次、巨型注入正文和子任务刷新混入的来源，没有测量用户机器上的 FPS，也不能宣布所有卡顿解决。

修复需要客户端与桥接都更新：仅换客户端不会修复旧桥接的分页边界和流式逻辑。已丢失来源字段的历史子任务消息不能凭正文安全区分，此次不会自动删除；未来可利用原始记录另做可审阅的历史恢复。已经存储的 skill 注入则能由新客户端重新识别并折叠。

当前只生成本地构建和提交，没有部署远端或替换用户安装的 App。正在运行的会话保持原状。

## 复现

```sh
python3 -m unittest discover -s remote -p 'test_*.py'
swift run --build-system native WorkbenchChecks
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py claude --output .local/claude-new-check
bash scripts/build.sh
```
