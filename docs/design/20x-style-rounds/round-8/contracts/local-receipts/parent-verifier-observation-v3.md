# v3 原件验证器初版负回执

父代理初版 `tools/verify-final-failure-v3.py` 对原tar摘要及35份文件摘要已核验，随后假定复用作业将原计划副本命名为 `plan-original-v3.json`，因该路径不存在而exit1，尚未生成数值结果。

实际作业只替换输入 `plan-v1.json` 为 `plan-v3.json`，保留原归档副本名 `plan-original-v1.json`；其字节应与v3计划比对，不是另一份旧计划。初版脚本及负回执不覆盖。v2只纠正此文件名，并将已提取的原文件逐字与原tar重新核验；存在时不重新提取、不改写原件。该父代理文件名错误与原GUI pilot FAIL区分，不更改原作业exit1。
