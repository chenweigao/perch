# S09 新 before 实际验证

- 唯一 `style-r6-before-v1` 于 2026-11-19 14:42:21 终结，末行 `exit=0`、done 存在；34 场景，capture 497.991 秒，源头 `2ded248b7f3d6993841b05c88b33f36add451a92`，前后共享 checkout clean。
- 实际 Mac 原始目录有 68 个真 PNG；每场景两次 PNG 字节、RGBA、白底可见像素、机位与 fixture 一致。日常八组和首次使用八组都在 manifest 用实际命令／环境证明，首次使用不是日常图重命名。
- 初次 Mac tar 含 68 个 `._capture.png` AppleDouble 元数据成员；GNU tar 还报告扩展属性 keyword 警告。首次严格 consumer 把 136 个 PNG 后缀文件全计入而 exit 1，原 `before-original-validation.json` 的失败不改写。
- Mac 只读查询证实真 PNG 68 个；额外成员均为 AppleDouble magic `00051607`、不是 PNG。原包／初次原提取完整保留，逻辑读取仅排除经验证的传输元数据，其他图片、JSON、日志字节逐一与原提取相同。见 `archive-transport-observations.json`；没有新 GUI、重拍、缩放或换基线。
- `before-original-validation-v2.json` 及发布副本验证均 PASS，发布 345 个 capture 文件、68 原 PNG 字节不改；文本仅机器 home 前缀脱敏。`comparer-controls.json` 的 26 项完整控制 PASS、345 份 before 输入及冻结输入不变，合成图仅在外部证据目录，不作交付截图。
- 实际查看 `baseline-visual/headers-first-use.png` 的八组：状态当前值均仍为 `首…`；标签完整、S03 两项当前值完整。日常八组为完整 `日常`。同时查看英文 xxxLarge dark 全窗口，未见本轮 before 新重叠；这些图片均绑定本轮真实原图与 3× nearest 来源。
- before／目视／完整控制全部通过后才改产品一行；source-scope 和 source-change.diff 记录真实来源。Linux portable 后续实际 10/10，运行在产品写入后／提交前、HEAD 为 baseline、dirty=true；Linux 无 Swift，WorkbenchChecks 未执行。新 after 和 Mac gates 才认证新候选运行，不扩大这份 before 认证范围。
