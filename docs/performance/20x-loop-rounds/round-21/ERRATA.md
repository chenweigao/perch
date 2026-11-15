# Round-21 errata（复核发现 1/6 处置；历史证据不改写，以本文件勘误）

## E1 — v1/v2 补丁与提交说明中的哈希回退表述（复核 F1）

`rejected-bytekey-withutf8.patch`（= git 历史 2aa8d97 的 ByteText 注释）
与提交 a7332c8/2aa8d97 的说明中声称：
"`withContiguousStorageIfAvailable` returns nil for the substring-backed
Strings that clean()/narrativeText() produce, dropping every hash into the
same per-byte iteration"。

**勘误**：v1 候选侧画像证伪该概括——`ByteText.hash` 的 1,136 个样本中
**1,123 走 `withContiguousStorageIfAvailable` 快路径成功**（叶为
`Hasher.combine(bytes:)`），仅 **9** 样本含 `Array.init` 回退（一例被检
链为 localHeadline 下的桥接 NSString）。逐字节 witness 陷阱全部位于
**等值比较**：`ByteText.==` inclusive 3,000 样本中 1,892 为
`Collection.subscript.read in conformance String.UTF8View`（经
`Sequence.elementsEqual → IndexingIterator`）。substring-backed String
对 `withContiguousStorageIfAvailable` 的 nil 频率未单独实验归档，不作
断言。v2 的 withUTF8 修复对两条路径同样有效，撤回决定不受本勘误影响。

## E2 — attr-job-cand-v2.sh 头部状态回显（复核 F6）

归档脚本头部 echo 为 "product_state=a7332c8-equivalent"；实际该作业应用
r21v2-product.patch，产品态为 **2aa8d97-equivalent**（评审方以内存补丁
应用验证）。对应 runner 日志（attr-v2-runner.log）中的历史回显保持原样，
以本条勘误。归档脚本副本的标注已同步更正。

## E3 — screen-mac-v2b.sh 头部迭代数（复核 F6）

头部注释沿用 v2 首轮的 "3 alternating iterations, presentation-token +
streaming + mode 1"；该脚本实际执行 **6 轮交替、仅 presentation-token**
（可执行体正确）。归档副本头部已更正。

## E4 — summarize-r21.py usage 行（复核 F6）

docstring 的 Usage 行沿用模板名 "summarize_r16.py"；实际用法：
`summarize-r21.py <pair-log-dir> <out-summary.json>`。归档副本已更正。
