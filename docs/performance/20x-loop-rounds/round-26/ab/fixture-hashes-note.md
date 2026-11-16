# Fixture hashes note (round-26 formal A/B)

The Mac formal job omitted the fixture-hash dump (screening-template
line not carried into the formal adaptation — disclosed as an archival
gap, not a data gap). Fixture identity is established from git state
instead, equivalently:

- The Linux formal job dumped `git show 77157a9:<bench file>` hashes
  (linux-fixture-hashes.txt, this directory).
- Bench files are byte-identical across base/candidate on BOTH sides:
  the r26 tests patch touches only NarrativeDelimiterScanTests.swift
  (new) and ProtocolTests.swift (one registration line); the product
  patch touches only ActivityNarrative.swift and
  ConversationProjection.swift. The verification command (corrected per
  review F10 — the original note listed bare basenames after the first
  path, which git resolves against the repository root):

      git diff 668ec61..77157a9 -- Tests/WorkbenchCoreTests/{PresentationBench,StreamingBench,ActivityBench,EditLineBench,BenchClock,LinkScanMaterializeTests}.swift

  is empty,
  and the Mac job checked out exactly 668ec61 before applying those
  patches (driver log HEAD line + porcelain 0/0). The reviewer
  independently verified the full diff, all six source-file SHA values
  and the round-23/24 manifests — all identical.
- The values match the round-23/24 archives (same bench sources since
  round-21).
