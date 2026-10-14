# 刷新缩高时同步钉回裁剪区

用户报告：点开很久没看的会话，正文不停闪烁，直到积压事件消化完。
机制：补差期间每个结束的轮次把展开的过程行折叠成一行（foldsProcess），文档高度骤缩；
clip 仍停在旧位置且整个落在新正文之外。AppKit 对裁剪原点的回夹晚一个显示周期，
`viewWillDraw` 的补挂载无法覆盖"视口在正文外"的情况（PR #81 CI 遗留失败，
clip 73,905 vs 新正文 71,075pt）。每结算一轮空一帧，表现为持续闪烁。

## 改动

`refreshVisibleRows` 在挂载可见行前检查：视口完全超出正文末尾、且文档 frame 尚未跟上
内容高度（`abs(bounds.height - totalHeight) >= 1`，据此避开弹性过卷）时，同步把 clip
钉回有效范围——有待恢复的阅读目标时落到目标行，否则落到新末尾——再继续挂载。
不等 SwiftUI 内容尺寸往返和 AppKit 的延迟回夹。

## 验证

- 挂载夹具新增确定性回归：缩高到 2 行（视口原本在约 74k pt 处）必须同步回夹且有可见行；
  带恢复目标缩高到 31 行时必须直接落在目标行。关闭生产修复后夹具按预期失败
  （"Shrink left the clip outside the body for a display pass"），开启后通过。
- `kimi-refresh` 连续 5 轮（30 次切换）通过；`kimi-switching`、`paging`、
  `detail-lifecycle`、`all`（含上述新检查）通过。
- 生产 Release 构建与严格签名通过；WorkbenchChecks 通过（live SSH 未设置，跳过）。

## 边界

覆盖"刷新后视口整个落在正文外"的空白帧；部分重叠（下缘短暂露出旧 frame 背景）
不在本范围。闪烁的另一来源（补差本身导致的频繁重排）未改动；夹具证据是原生布局采样，
不含显示帧率，真实会话体感需安装后确认。
