# I02：进程内静态窄窗捕获（修改前冻结）

2026-11-20。继续同一假设，不采用 PLAN.md v1 的外部 AX 改窗方案：实际只读回执 `node_child_AXIsProcessTrusted=false`，该路径已停止，没有请求／更改权限或 GUI 动作。

修复写集限定为 `Tests/HostLifecycleChecks/StyleCapture.swift` 中截图专用 `present` helper 的 opt-in 内容尺寸，以及一个新增截图脚本。前者不是功能验收断言、测量或 CI 门槛：仅已有 `PERCH_STYLE_CAPTURE` 生效且显式传入新的 `PERCH_STYLE_CAPTURE_SIZE` 时使用参数；无参数时逐句保留既有窗口尺寸、位置、fixture 状态和 ready 语义。不改正常 native-design 路径、不新增 fixture／preview、不改 Sources 或已有脚本。

## 单一假设与预期差异

- 正常动态验收里的 685 像素原差异不回写或豁免。新窄窗基线复用已有静态截图 fixture（既有 stopped 状态），在进程内设为 836×900，原固定位置 48/72 不变；不能说新图等于旧动态功能图。
- 新脚本只调用同一 native-design capture 入口，沿用中／英文、light／dark、14／18pt 的既有变量、Node 录屏链和原 PNG。
- 新 A/B 必须相同 app、场景、环境、位置／尺寸、ready 与截图驱动；PNG 字节、RGBA／整数白底 visible／alpha 全部零差异。
- 既有静态 fixture 的 busy 已关闭，这是旧 capture 模式的行为，不是本轮改会话状态；已存在的窄窗侧栏遮挡不冒称被修复。
- 正常 34 场景的默认尺寸不改变；正常 11-gate、5 冷启动、原 native-design 断言与测量语义不改变。
- 任何清单外产品／布局／材质变化、捕获失败、零容差失败、机位漂移、非 fixture 窗口操作或权限变化均阻断恢复。

## 证据顺序

1. 本地静态与脚本契约检查、portable；保留旧 829ba3a9 正常窄窗原件和失败判定。
2. 只提交本轮聚焦候选和预写清单到长期 style 分支；不合并、不 PR。Mac 先 fetch／checkout 同候选，PerfRunner 构建原 HostLifecycleChecks 目标。
3. 新作业先两次中文 light 14pt 窄窗；原 PNG 字节相等才追加八个既有语言／外观／字号组合及普通 34 场景 A/B。
4. 门槛与视觉恢复通过才派一次指定独立复核；完成后归档计数，再从原队列继续，不问用户继续。

当前 round 8 / I02 未完成，`delta=0`，距汇报仍14轮。
