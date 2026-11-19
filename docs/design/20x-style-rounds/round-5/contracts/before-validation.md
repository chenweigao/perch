# Round 5 新基线核验

- 真实基线`566c0c3e449fa076adbee1d91a9002ddd561034d`；同一PerfRunner作业从10:51:47运行至10:59:27，末行exit=0、done存在、队列文件消失。
- 27场景、54原PNG；两次实际解码和hash验证均27/27重复PNG字节、RGBA、白底可见像素一致。window／ready元数据一致，机位、backing scale、语言、字号及有效明暗正确。
- 九个Workbench场景1120×820、scale1；冻结半开允许矩形仍`[544,48,1112,104)`。清单和允许区的Mac作业副本与首次预写hash一致，不使用mtime替代首次写入证据。
- 九组原header及英文完整窗口实际查看：任务组中英当前值截断，英文机器值截断；中文机器已显示完整。未见标签互相重叠，目标不是藏标签或压缩字体。
- `预览状态`标签仍中文，`workbench-empty-light`当前值已有截断；这些既有fixture／本地化现象不属于S03修复，不隐瞒也不在本轮扩面。
- 大字fixture沿用StyleCapture的xxxLarge代表设置，不宣称所有原生控件18pt或全应用任意宽度验收。系统外观／Settings策略和默认light fixtures的运行边界仍按轮次报告保留。
- 19个合成比较器控制全通过，源矩阵275文件与当时契约输入hash未变；合成输入外部存档，不进入交付原PNG。
- before通过后才写两行产品候选；after、生产build、WorkbenchChecks、5/5冷启动、正常native-design和新独立评审此时尚未执行，不记PASS或完成。
