# Round 6 / S09 独立评审逐字处置

日期：2026-11-19。原评审 `review-6.json` 的 `PASS_LIMITED`、P1 0／P2 0／P3 1 保持原判；只认证真实候选 `7e66eb2e5a9dac92eea8d6178e55e7ab5f38e554` 的冻结契约，不作审美裁决。原评审、seal、PNG、日志、预写差异与允许区均保留原字节。

## S09-R6-F01 — P3，非阻断

原发现逐字保留：

> after 本地消费整体 shell 的 141 按父代理实际工具回执及 README:41／after-consumer-observations.md:7 保留；已独立核对原包、原件／发布 hash、比较结果及 Mac 作业 terminal exit0，但本次读取的冻结输入没有该次 shell 原 process 的数字退出码与末段 jq|head 管线的原始完整回执。不能把 141 表述为本评审从原 process 记录独立读出的退出码，也不能升级整体 shell 为 exit0；最后摘要管线 SIGPIPE 的解释保留为父代理操作回执记录，不当作本次重新认证的 GUI／像素／Mac gates 失败或取证因果。本项仅为非阻断 P3 回执精度边界，不重跑消费器、GUI、构建或任何配置／权限操作。

处置：接受并保留回执精度边界。141 仅是父代理当时实际工具回执；SIGPIPE 仅是当时操作解释，原冻结输入不足以独立认证原 process 数字退出码或完整管线因果。README 明确这一区分，不把整体 shell 改判为 exit0，也不把此项写成 GUI／像素／Mac gates FAIL。没有补造回执、重跑作业、修改产品或改动 TLS／credentials／hook／scanner／权限配置。

再验：使用既有 `contracts/verify-review-archive.py`，显式传入原 seal SHA256 `4b503ba3889c907a5717dc801b24bd9fc9b2e39f2181e7f4a3685b171894bc18`、原评审 SHA256 `5918281ee481c5158ec02cc6c88de4f6396abd4dc18ba5593df0852db8540fb2` 及 `--allow-authored-snapshots`。核对完整逐字引文、UTF-8 摘要、7772 项 hash／mode／kind、历史发现与源码零 diff。只有 README／INDEX 作者说明使用 `contracts/review-original-authored/` 中按原字节保存的对应快照，其余输入不豁免；实际结果另存为新文件。

## 历史发现与认证边界

- round 2／3／4／5 的 19 条原发现、原对象、原评审摘要及原 verdict 全部保留。round 2 仍为视觉 `FAIL`／完整契约 `NOT_PASSED`、产品撤回；round 4 原 `FAIL` 与后续目视 `PASS_LIMITED` 分别保留。
- 原评审 R6-L01–R6-L17 全部保留，不扩大冻结的 34 场景、1120×820／scale1、十六 header 或所看原图的认证范围。xxxLarge 不等于全应用 18pt；系统跟随源码不变不等于全局 OS 切换认证；正常 native-design view-cache 不等于完整 compositor 光学或审美批准。
- Linux 只认证实际 portable 10/10，不声称 Swift／WorkbenchChecks、clean 候选来源或完整 Linux PASS。真实会话／SSH／agent／凭据／权限、性能、可重复构建、全部图片隐私及全历史审计均不扩认。
- 完整 whitespace 诊断和原日志空白保留；限定排除原证据日志之外通过不写成全量 PASS。scanner 的 0 findings 仅是既有规则结果。
- 评审与本处置本身不计完成。先正常同轮归档、精确远端与源码保护核验，再单独记录 15→14；最终归档头不冒充重新运行 GUI 的测试头。不开 PR、不合 main，不重派已完成作业或评审。
