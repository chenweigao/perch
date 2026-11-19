# Round 5 回归观察与认证边界

## 已核对策略

- 生产`WorkbenchApp`仍以`.system`作为AppAppearance默认值，system返回nil colorScheme，Settings仍提供light／dark；本轮Sources全零diff，不把静态保持写成已测试全局OS切换。
- 既有Workbench root仍使用`StyleCapture.colorScheme`、locale和dynamicTypeSize。无dark变量时light；只有显式截图dark才使用darkAqua。原StyleCapture源码未改，默认acceptance／preview fixture不改跟随系统策略。
- StyleCapture仍固定窗口origin `[48,72]`、contentSize并把鼠标移到 `[0,0]`；本轮独立比对window与ready、backing scale及有效明暗，不以窗口编号相同作为可比条件。
- before九组Workbench截图覆盖中英×默认／xxxLarge×light／dark八组合及existing empty light，均已目视；27场景还包含main十三、Sidebar三和Composer二。
- 放大fixture是xxxLarge代表环境；主窗口正文可为18pt，但不声称所有原生Picker、explicit font或任意窗口宽度／菜单最长值都放大到18pt。

## 需保留的既有现象

- 原英文Task Groups仅ellipsis、Machine为All…，中文任务组值全部…；中文机器原本完整。这是S03目标，after须证实恢复完整与无重叠。
- 预览状态标签／选项在英文fixture中仍中文；首次使用值已有截断。本轮不改该Picker、文字、字体或130pt硬frame，不把它们认证为全窗口无截断。
- 27/27 repeat与严格允许区不等于全compositor稳定性、任意OS状态、真实连接／权限或性能认证；GUI运行保持离线synthetic bundle，真实用户会话未使用。

## 此记录阶段尚未完成

- 新after仅入队；未把入队回执当视觉PASS。
- 新Mac production build、实际WorkbenchChecks、5/5 cold launch与正常非capture native-design尚未执行，不认证。
- 新独立目视与合同复核尚未派发；本轮未计完成，距汇报16轮。后续实际结果单列，不追改此阶段的未执行事实。
