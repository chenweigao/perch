# I01 回归观察与认证边界

实际候选：`025dc61cafa32e0e61eef2c4ef3ca8ea3a063d5e`。本次观察使用 after-A 原 PNG；before/A 的其他 20 场景经过零容差比较，几何、颜色与可见文字完全不变。

## 代表性原图

- 中文／放大：[main-large-type](../after-a/main-large-type/repeat-1/capture.png)。S01 的 `Recap` 标签仍完整；inspector、阅读区与 composer 相对位置不变。
- 英文／默认：[main-english](../after-a/main-english/repeat-1/capture.png)。界面标签使用英语；fixture 会话正文与名称保持原有离线合成内容，未换成真实会话。
- 英文／放大／light：[main-english-large-type](../after-a/main-english-large-type/repeat-1/capture.png)。未引入新重叠；inspector 标题既有省略仍可见，属于 S02 队列，不写成完全无截断。
- 英文／放大／dark：[main-english-large-type-dark](../after-a/main-english-large-type-dark/repeat-1/capture.png)。同一 fixture、相同机位；本轮不改主窗口的明暗 token 或字号。
- Composer light：[before](../before/composer-light/repeat-1/capture.png)／[after-A](../after-a/composer-light/repeat-1/capture.png)。只出现声明内的一条背景合成边界差异，布局不变。
- Composer dark：[before](../before/composer-dark/repeat-1/capture.png)／[after-A](../after-a/composer-dark/repeat-1/capture.png)。背景使用已有内容色，文本、chip、控件和原生 composer 几何不变。

## 契约边界

- 全矩阵包含中英文主窗口默认／放大字号与 light/dark 的组合、查找栏与 inspector 关闭等状态，以及三个既有 preview。未新增 preview、fixture 内容或验收页。
- `source-scope.json` 证明本轮所有生产 Sources、theme、scripts 与 CI 相对 before 零 diff，两个实际源文件与候选逐字节匹配；源码层没有改变系统外观跟随、Settings 覆盖或已裁决玻璃／圆角规则。
- `AppAppearance.system.colorScheme` 仍返回 nil，主窗口继续读取该策略；三个 preview 仍由 `StyleCapture.colorScheme` 默认选择 light。capture dark 由显式 fixture 环境选择，不修改用户系统设置。
- I01 的 container 背景仅在 `StyleCapture.isRequested` 为 true 时生效；非捕获路径仍返回原视图，共享方法默认背景仍为 clear。原生 Liquid Glass 控件本身没有改动。
- 正常非捕获态 native-design 已在 gates 实际运行并 PASS（27.94 秒），有原生 light/dark 与 12 张原截图回执；静态源码不替代运行证据，也不把 capture fixture 的 dark 当成系统跟随认证。
- 系统外观策略用生产 Sources 零 diff、`.system` 仍返回 nil 核对；原生运行实际检查显式 light/dark 覆盖到窗口。本轮未改系统全局明暗，未另作全局切换的运行认证，也不宣称所有普通 preview 的人工交互全部验收。
- S02 的 inspector 标题与 S03 的 Workbench preview 筛选器仍有既有截断，I01 不修这些队列项、不宣称全产品已无截断。这里只证明本轮没有引入新截断／重叠或清单外改变。
- after-A 的单作业双跑与区域检查本身不等于跨作业稳定性；随后 `cross-job-stability.json` 已用两个独立作业、相同候选头、无允许区验证全量 22 场景零差异，原 PNG 也 22/22 字节相同。完整 Mac gates 已实际执行成功，独立评审结论仍待完成。
