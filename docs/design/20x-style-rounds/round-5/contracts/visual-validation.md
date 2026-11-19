# Round 5 视觉层实际结果

- before与after各27场景、54原PNG；原件与发布副本都重新解码、核对hash及window／ready／camera／fixture，矩阵各27/27重复PNG字节、RGBA与白底可见像素一致。原文件未改，发布文本只脱敏机器home前缀。
- 同一after作业11:21:58入队，11:29:05终结exit0，410.622秒；真实源码头`0b05897bad0dfaa22aef446422bbd3a5c31f92ea`，前后shared checkout clean。原job／原图／首次TLS错误均保留，不重派旧作业。
- 27场景区域比较实际PASS：九个WB header仅冻结区域内改变，其余十八全窗口RGBA及可见像素零差异。清单、允许区与frozen contract未改，不在看到after后扩大区域。
- 英文四组合changed bbox `[546,66,1072,90)`，可见／RGBA像素分别8201、8413、8201、8413；中文常规与large/light 7092、dark 7243，empty light 7156，中文bbox `[646,66,1072,90)`。九场景全部落在原半开`[544,48,1112,104)`内。
- 九组3×nearest原header对与英文完整light／dark窗口对已实际目视：`All task groups`／`All machines`、`全部任务组`／`全部机器`完整，标签及箭头无新重叠。Workbench标题及其余几何不动；字体、预览状态的原文字及既有首次使用截断未改变。
- 派生图不是新的交付截图；原图可复算，来源、原sha、裁剪与重采样在comparison/provenance.json。主窗口13场景、Sidebar3、Composer2仍零差异，S01／S02／I01既有结果保留。
- 此结果只认证已冻结机位、fixture及九项文本宽度，不扩大为任意窗口／菜单值、全原生18pt、全局OS切换、完整compositor、真实连接／权限或性能认证。
- 新生产build、Mac WorkbenchChecks、5/5冷启动、正常native-design与独立复核尚未在此记录阶段完成；本轮仍未计完成，距汇报16轮。
