# Native 连接自适应轮询（2026-10-09）

## 改动

空闲连接的轮询循环不再固定每 400ms 唤醒主 actor：

- `sleepUntilNextPoll` 睡到下一个到期读（目录 5s / 快照退避）为止；忙碌会话、
  待处理交互、在途发送保持 400ms 快 tick。
- 空闲快照读在内容不变时按 2s → 4s → 8s 退避；读到变化、选中会话的目录项变化、
  历史窗口扩展、select/disconnect 都重置回 2s。
- `send`/`select`/`disconnect` 通过 `wakePolling` 立即唤醒循环；审批、停止、
  模型与权限修改本来就走 `action()` 直连刷新，不依赖 tick。
- `refreshSelected` 返回是否应用了新快照；先排程再读取，保留"历史窗口扩展后
  下一轮立即补读"的契约（回归见下）。

## 验证

ConnectionChecks（注入 transport、虚拟时钟驱动 `poll(now:)`，3 轮全绿）：

- 既有 `checkIdleSnapshotPolling` 不变量保持：内容持续变化时 8s 仍 4 次读，
  运行中与待审批保持每个 tick，失败/暂停的发送不加速轮询。
- 新增 `checkIdleSnapshotBackoff`：不变读在 24s 窗口内落到 0/2/6/14/22s 共 5 次
  （固定节奏为 12 次）；变化重置回 2s；忙碌每 tick 全量。
- `checkNativeLoading` 的历史窗口扩展契约保持（本轮修复点：预排程 + 读内覆盖）。
- WorkbenchChecks、native acceptance `switching`（80 次切换、目录变换、收藏
  增删）通过；idle CPU 2s 窗口 0.058 CPU-s（历史参考 0.082–0.123，非同机严格
  对照，仅说明无回退）。

## 边界

- 节奏证据来自注入 transport 的虚拟时钟测试，不含真实 SSH 时延与系统定时器
  合并；省电量级需长时真实使用采样另行确认。
- 唤醒丢失的最坏后果是空闲读延迟到下一个到期点（≤8s）；发送/选择因此走
  `needsFastTick` 或直接读，不依赖唤醒。
- 目录节奏（忙碌 2s / 空闲 5s）未改；其它主机的独立连接各自退避。
