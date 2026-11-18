# Fresh before 核验

2026-11-18 21:32（+08:00），产品修改之前完成。

- 同一 `style-r4-before-v1` 已有 `.done` 与末行 `exit=0`；作业21:20:31开始、21:27:23结束，没有重派。
- 精确源码 `aad604b9ce5294b52951f189b3895b69edd12f31`，作业前后porcelain均0；host binary SHA256 `5c83ea549333b713e764d397a88646afac324ab1c061350b39d51336772d8eec`。
- manifest包含22场景、44原PNG与92命令：4个构建与44个screencapture均`exit_code=0`，44个持久fixture在截图后由既有driver主动SIGTERM，记录为-15；三个既有preview与host本轮重建。此处是捕获构建，不代替之后生产build或完整Mac gates。后处理误把fixture也要求为0的诊断错误另见[记录](postprocess-observation.json)，原件不改。
- 双跑22/22原PNG字节相同；[stability自比](before-self-check.json)与[header自比](before-header-self-check.json)均22场景零RGBA/可见差异。
- [机位元数据](before-geometry.json)：代表主窗口1536×900、backing scale 1、frame `[48,72,1536,900]`、content bounds `[0,0,1536,900]`；ready/window元数据一致，语言、外观与字号fixture匹配。
- 显式查看中文/英文、默认/放大、light/dark八个原图header的3×nearest裁剪，以及英文放大全窗口。中文标题和`2 个文件`完整；四个英文代表场景均为`Current workspac…`，计数`2 files`完整。
- 冻结半开区域`[1218,44,1530,96)`完整覆盖同一inspector header，不包含toolbar、首条文件行或阅读/composer区域；不因after结果调整区域。
- [完整header CLI控制](comparer-header-cli-controls.json)五项通过：无变化、允许区内单像素、文件行越界单像素、Composer越界单像素、hash破坏。所有225份原capture文件hash在控制前后不变；合成输入仅外部保存，不是交付截图。
- 初期controls仅用旧round3原件与函数层控制；[初期记录](comparer-controls.json)保留，不把它替代上述fresh-before完整CLI证据。

放大fixture声明`.xxxLarge`，主窗口同时使用现有正文18pt设置；inspector标题仍用固定`Typography.title`（14pt），计数用`Typography.caption`（12pt），父容器为`Typography.body`。八场景能认证这些代表性设置下header完整性，不能外推为全应用18pt或任意字号/宽度均通过。

原件存于本轮外部_evidence，发布图像逐字节相同，仅文本机器home路径脱敏。产品、其他Sources、scripts与CI在此核验前零diff；清单和允许区hash仍与首次写入回执相同。
