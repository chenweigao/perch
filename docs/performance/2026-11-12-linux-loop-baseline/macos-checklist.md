# macOS 侧基线测量清单（20x 盘点轮，待 Mac mini 接入 T3 后执行）

前提：`scripts/build.sh`（Xcode + Swift 6.4.x，Apple silicon）。每项连续跑 ≥3 次，
记录中位数与噪声带；对照改动时基线/候选交替运行（NATIVE-PERFORMANCE.md 纪律）。
所有产物存 `.local/`（gitignore）。

## A. 会话切换卡顿（头号 20x 候选：2026-10-24 报告 1.3–1.6s 未归因）

1. 真机帧诊断（用户自己的会话数据）：
   Settings → 诊断 → 开"性能诊断" → 注入 120ms 卡顿校验 → 复现切换 →
   导出 `perch-diagnostics.json`。
   关注 `blame` 里 `session_select` / `snapshot_projection` / `catalog_refresh`
   的 self ms 与 `unattributed_ms`（FRAME-DIAGNOSTICS.md）。
2. 合成验收入口（固定条件 1280×820、500 会话、8×200 轮）：
   ```sh
   scripts/build-native-acceptance.sh
   python3 scripts/run-native-acceptance.py --mode switching --output .local/na-switching
   python3 scripts/run-native-acceptance.py --mode all --output .local/na-all
   ```
   记录 SessionSwitch signpost 的 model.open → 布局完成区间。

## B. 冷启动

```sh
python3 scripts/check-app-launch.py --app build/Perch.app --output .local/launch-check
```
5 个全新隔离偏好域下的 WindowGroup 冷启动；记录每次启动耗时分布。

## C. 滚动 / 帧

```sh
python3 scripts/run-native-acceptance.py --capture frames --positive-control --output .local/na-frame-cal
python3 scripts/run-native-acceptance.py --capture frames --output .local/na-frames
python3 scripts/run-native-acceptance.py --capture cpu --output .local/na-cpu
```
注意：hitch 检测校准自 2026-09-23 起未通过，必须先跑 positive control；
帧生命周期数据不能声称 FPS。

## D. 空闲资源（footprint / RSS）

按 2026-11-02 报告方法：同一工作负载前后 footprint/peak 采样 + 静置回落。
历史参照：336.4MB footprint / 522.0MB peak（build 928，用户真机样本）；
133.6MB / 227.3MB（build 927，Mac mini 5s 样本）。目标待定基线后设定。

## E. 数学 A/B（macOS core 组）

```sh
scripts/check-math-performance.sh .local/math-perf
```
基线为 PR base（或设 WORKBENCH_MATH_BASELINE_REF 钉死 commit）。

## F. 模型层对拍（与 Linux 循环同源同 bench）

```sh
swift build -c release --product WorkbenchChecks
WORKBENCH_BENCH=streaming .build/release/WorkbenchChecks
WORKBENCH_BENCH=1 .build/release/WorkbenchChecks
WORKBENCH_BENCH=activity .build/release/WorkbenchChecks
```
用于确认 Linux x86 与 Apple silicon 的相对结论方向一致（绝对值不可互比）。

## 输出

每项记录：日期、build/commit、机器、运行次数、中位数、噪声带、命令与产物路径。
汇总进基线盘点报告，按"当前值 / 理论或产品目标 / 余量倍数"排出 ≥20x 候选场景。
