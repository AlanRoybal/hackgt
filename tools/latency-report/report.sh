#!/usr/bin/env bash
# p50/p95 per pipeline stage from CloudWatch (namespace Nudge/Latency, emitted by the backend via EMF).
# Usage: tools/latency-report/report.sh [hours=24]
set -euo pipefail
HOURS="${1:-24}"
START="$(date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PERIOD=$(( HOURS * 3600 ))

printf "%-12s %-10s %8s %8s %8s\n" pipeline stage n p50_ms p95_ms
aws cloudwatch list-metrics --namespace Nudge/Latency --output text \
  --query 'Metrics[].[Dimensions[0].Value,MetricName]' | sort -u | while read -r PIPE STAGE; do
  aws cloudwatch get-metric-statistics --namespace Nudge/Latency --metric-name "$STAGE" \
    --dimensions Name=pipeline,Value="$PIPE" --start-time "$START" --end-time "$END" --period "$PERIOD" \
    --statistics SampleCount --extended-statistics p50 p95 --output json |
    python3 -c "
import json,sys
d=json.load(sys.stdin)['Datapoints']
if d:
    p=d[0]; e=p.get('ExtendedStatistics',{})
    print(f\"%-12s %-10s %8d %8.0f %8.0f\" % ('$PIPE','$STAGE',p['SampleCount'],e.get('p50',0),e.get('p95',0)))"
done
echo
echo "Targets (SPEC §2.5): utterance end → chip p50 ≤ 2500 ms, p95 ≤ 4000 ms (reference/total + on-device Transcribe final ~700 ms);"
echo "Show → visible on both p95 ≤ 800 ms (measured by tools/peer-bot two-bots)."
