# S02 回归证据与认证边界

实际候选／测试头：`4b64796633d4cee9db9ac10bbc1ea8b2f4ea4da1`；新before：`aad604b9ce5294b52951f189b3895b69edd12f31`。
before与新after已完成并核验；新Mac gates也实际终结并归档，包含正常非捕获态native-design，不由作业脚本存在推断PASS。

## 不变的契约

- 本轮产品只修改`ChangesInspectorView.header`外层HStack间距6→0，内部标题／计数6pt、Spacer4pt、padding、字体、返回／菜单／关闭控件尺寸与处理器不改。
- 其他Sources、theme、Tests、scripts与CI相对新before零diff。单系统玻璃、glassUnderlay四档、独立明暗token、平面sidebar、内部inspector留白分隔与外sheet同心圆角都不重开。
- `WorkbenchApp`继续读取`AppAppearance`，`.system.colorScheme`仍为nil；Settings覆盖策略没有变化。该源码证据不能替代操作系统全局明暗切换的运行认证。
- 三个既有preview继续由`StyleCapture.colorScheme`默认选择light，dark仅由显式capture环境选择，不改变用户系统外观；I01的捕获态Composer背景保持原修复，不修真实用户数据或远端连接。
- inspector宽度、reader/composer联动几何与页面导航没有产品变化；不添加卡片、边框、阴影、preview或其他平台，不执行真实SSH会话、takeover或权限绕过。

## fixture 及已知局限

- 主窗口矩阵包含中文/英文、默认/放大、light/dark八组合，另有find、find-dark、inspector关闭、dashboard和scroll；三个既有preview共八场景，总计22场景、各双跑。
- `StyleCapture`对放大场景声明`.xxxLarge`；`NativeDesignChecks`同时把正文设成18pt。标题仍为固定14pt、计数固定12pt，不声称整个应用字体都放大到18pt或任意字号/inspector宽度均不截断。
- 八个before header代表裁剪确认中文标题／计数完整、英文标题截断且`2 files`完整；after必须显示完整`Current workspace diff`和`2 files`且无重叠，不能以缩字、隐藏计数或扩大允许区交付。
- S01的`Recap`及其他清单外区域应逐像素不变；S03的英文Workbench筛选器既有`All…`属于下一队列项，不把S02成功外推为全产品没有截断。
- 后续Mac gates须正常非捕获态运行native-design，实际检查应用light/dark覆盖并归档截图；未另操作系统全局外观，未另认证所有普通preview人工交互。

## 结果待补

- after双跑及before/after的RGBA／可见像素零容差区域比较：22场景通过，88原PNG；11个header场景变化仅在冻结区，其他11场景零差异。
- 标题与计数、八场景代表图及两张完整窗口对比：已显式查看；四个英文组合的标题／计数完整，中文仍完整，未引入新重叠。详见[视觉验证](visual-validation.md)。
- Mac生产build、WorkbenchChecks、5/5冷启动、radius/localization及正常native-design：新gates于21:54:34终结`exit=0`，均实际PASS；正常native-design 27.70秒、有12原PNG，捕获态环境已unset。
- bundle冷启动revision为实际`git describe`值`v0.8.1-313-g4b647966`，完整checkout SHA另核为`4b64796633d4cee9db9ac10bbc1ea8b2f4ea4da1`；不把描述stamp与40位SHA混为一谈。
- [Mac gates核验](mac-gates-verification.json)确认host binary与after相同、前后checkout clean、生产source与真实测试头字节相同；源码不变证据与正常原生light/dark覆盖执行证据分列，仍不声称操作系统全局外观切换已认证。
- 独立复核：尚未派发；本轮不计完成，仍距汇报17轮。
