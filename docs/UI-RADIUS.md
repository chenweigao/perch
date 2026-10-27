# UI 圆角规范

Perch 的圆角按组件用途取档，不按内容长度临时取值。规则受 DeepSeek Harness 的
ui-radius 规范启发；数值以 Perch 的既有 token 为准。执行方式：任何裸数字圆角
必须由 `scripts/radius-exceptions.json` 逐项钉住，否则
`scripts/check-radius-tokens.py`（portable 检查套件的一项）失败；失效的钉子
同样失败。

## 档位

| 用途 | 数值 | token |
|---|---|---|
| 小元素、chip、缩略图 | 5 | `WorkbenchTheme.Radius.chip` |
| 行高亮、紧凑控件、会话行 | 10 | `WorkbenchTheme.Radius.row` |
| 分组内容、卡片、通知 | 10 | `WorkbenchTheme.Radius.card` |
| 窗口框架里的面板：侧栏、对话卡片、检查器 | 20 | `WorkbenchTheme.Radius.panel` |

家族常量（如 `UserMessageStyle.cornerRadius` 18、`ReplyStyle.Code.cornerRadius` 8）
是组件族的几何声明，保留原名，但必须钉在例外清单里——清单即目录，翻看它就知道
全 App 有哪些圆角。玻璃表面的系统材质按 AGENTS.md 保留；侧栏玻璃与外层裁切共用 20pt 面板 token，输入框玻璃也为 20pt。
右浮层与正文卡片用 12pt 材质沟槽分离。

## 规则

1. 新界面先用三档 token；都不够才声明家族常量并钉入清单；不直接写裸数字。
2. 嵌套表面同心内缩：内层 R = max(0, 外层 R − 内缩距离)。
3. hover、选中、焦点只改底色，不改圆角。
4. 圆形（头像、状态点）用 `Circle`/`Capsule`，不占档位。
5. 绘制细节（引用条、刻度线等宽度 ≤ 2 的装饰）可用小圆角，钉入清单并注明
   「drawn detail」。

## 修改例外清单

钉子的 key 是「文件 + 去掉首尾空白的整行」。改动了带钉子的行就同步更新清单，
否则检查会以「stale pin」失败——这是特性：任何几何变化都是一次有意识的决定。
