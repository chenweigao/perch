# Round 5 / S03 独立评审逐字处置

日期：2026-11-19。原评审 `review-5.json` 的 `PASS_LIMITED`、P1 0／P2 0／P3 1 不改写；限定冻结契约，不作审美裁决。所有原日志、PNG、预写差异、允许区、冻结契约和原 seal 保持原字节。

## S03-R5-F01 — P3，非阻断

原发现逐字保留：

> 首push的原日志保留TLS断连、unexpected disconnect和误导的Everything up-to-date尾句，但没有原process数字退出码行；exit1在本轮README:33与任务锚点中有记录，不能表述为本评审从push-initial.log独立读出的数字回执。远端失败后仍baseline、相同候选SHA正常重推及精确远端记录均已核对，故不把首推包装为PASS。这是负回执的退出码取证精度边界，不是产品、视觉或Mac gate失败；本评审不重推、不读取或改动TLS、credentials、hooks或permissions配置来补证。

处置：接受并保留取证精度边界。README 将数字 `exit1` 的来源明确限定为当时作者记录／原工具回执；保存的 `push-initial.log` 无独立数字字段，不能说评审从该日志读出了原process数字退出码。失败后的远端仍为真实 before、同一候选 SHA 正常重推和精确远端核验各自保留；失败日志尾句不升级为成功。没有补造历史数字回执、重跑 GUI、改动 TLS／credentials／hook／scanner／权限或产品。

再验：`python3 -B contracts/verify-review-archive.py --allow-authored-snapshots --output contracts/review-acceptance.json` 核对原发现 UTF-8 摘要、完整逐字引文、原评审／seal、6914 项 hash／mode／kind 和源码边界。命令从本轮目录执行；原说明文件先按原字节保存在 `contracts/review-original-authored/`，只有 README／INDEX 两份说明允许使用对应原快照核验。其他输入不豁免。

## 历史发现与认证边界

- 原 round 2 的四项、round 3 的五项、round 4 的九项共 18 条发现及原评审 SHA256 均保留；不在本轮追改等级、原文、处置或历史判定。原 round 4 目视补证也保持原字节。
- round 2 仍为视觉 `FAIL`／完整契约 `NOT_PASSED`、候选撤回；round 4 原 `FAIL` 与后续有限 `PASS_LIMITED` 各自保留。
- 原评审 L01–L14 未认证边界完整保留：固定九组当前值不是任意菜单值／窗口／locale／scale 认证；xxxLarge 不是全应用 18pt；旧状态截断 S09 不在 S03 修复；系统跟随源码不变不等于全局 OS 切换验收；native-design view-cache 不等于完整 compositor 光学或审美批准。
- 不声称 Linux Swift／WorkbenchChecks、clean 候选 Linux 来源、可重复构建、真实数据／SSH／agent／权限／性能、图片隐私或全历史凭据审计通过。保存日志空白及首次 push 负回执，不把限定检查写成全量 PASS。
- 评审完成和本处置本身都不计完成轮次；同轮归档、正常安全 hook、精确推送及源码零 diff 验证通过后，才单独记录 16→15。不开 PR、不合 main，不重复任何已完成作业。
