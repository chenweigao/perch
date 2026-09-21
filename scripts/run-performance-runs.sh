#!/bin/bash
# Drive the isolated performance fixtures unattended, alternating variants to
# reduce thermal/order bias. Touches only the two fixture apps.
set -euo pipefail
cd "$(dirname "$0")/.."
rounds="${1:-3}"
for round in $(seq 1 "$rounds"); do
    for scenario in assistant thinking; do
        if (( round % 2 == 0 )); then order=("Current" "Baseline"); else order=("Baseline" "Current"); fi
        for title in "${order[@]}"; do
            printf '=== round %s · %s · %s ===\n' "$round" "$title" "$scenario"
            PERFORMANCE_AUTORUN="$scenario" PERFORMANCE_AUTOQUIT=1 \
                "build/Performance $title.app/Contents/MacOS/PerformancePreview" 2>&1 | tail -2
            sleep 5
        done
    done
done
