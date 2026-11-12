# Round 7 短输入保护复核（替代 4560f8e 的性能合并证据）

独立评审未发现正确性问题，但指出小输入证据较弱。复查旧五对数据发现：Mac 8行
baseline第一对异常高，inflated spread掩盖了后四对的common编辑+约5–10%；Linux同类
+约5–11%。因此没有在旧head4560f8e即使CI全绿时合并。

## 修订

保留nil/empty规则之后，若old/new各自UTF-8长度都≤1024 bytes，则直接调用旧完整
分行算法，不先probe首尾。只是工作量选择，不改变计数或数据大小上限。大输入继续使用
经证明的无共同首尾/单行快路径。增加1023/1024/1025 byte边界oracle检查。

基准从8/64/512扩成8/16/32/64/512 ×10场景=50，并在两边相同fixture上重建。
两端仍为同Swift6.4默认builder、独立canonical原链接路径；五对固定AB/BA，hash恒定。
这里的数据来自新实验，不覆盖原始数据；旧五对所有九样本记录在父目录original-raw-*.json，
新实验全部九样本记录在raw-*.json。

## Mac结果

- 既有edit_stats@6400：3.220→2.499ms，**-22.39%**，最大spread约6.1%；两组范围分离。
- 小输入8行common场景五对median约-1%到-2.6%，没有旧版后四对稳定偏慢趋势。
- 新实验首个baseline进程仍有warmup异常，**全部记录保留**；单独观察第二至第五对只是
  诊断，不用“剔除首轮”制造结论。源码短输入直接走旧算法与这部分数据一起支撑修订。
- 50个Mac场景没有正向median变化超过当轮场景spread。这不是严格性能等价证明，也不
  承诺任何微秒级波动消失。完整各场景见macos-edit-lines.json，原始见raw-macos.json。
- 其他主要模型基准在噪声内；极小append打印仍有0.01ms量化，不能据此证明微秒等价。

## Linux结果和限制

- stats@6400：3.894→2.516ms，-35.39%。8行common约-1%到+1%，旧小输入退化已消除。
- 32行first仍约+4.8%（spread2.8%），另有少量32/64行common约2–3%偏慢；没有将这些
  数据删掉或声称Linux全场景无退化。目标产品是macOS，采纳依据限定为Mac。
- 所有oracle/checksum一致，Linux全套90PASS+1SKIP和portable10/10；Mac匹配baseline和
  candidate各91PASS，完整scripts/build.sh产品构建通过，修订后的Aqua隔离5次冷启动通过。
  baseline此轮也包含公共新增边界测试，所以不沿用旧实验90/91的计数。

新head必须做新的独立review及完整CI，不用旧4560f8e的全绿结果替代。没有修改外观、全局
memo、真实用户数据或远端会话，也不把模型收益推成whole-app/FPS或20x。
