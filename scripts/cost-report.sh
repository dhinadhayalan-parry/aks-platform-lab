#!/usr/bin/env bash
# Month-to-date actual cost by service, straight from the Cost Management API.
# Cost data lags usage by 8-24 h; the trial credit balance itself is shown in
# the portal (Cost Management > Credits).
#
# Usage: scripts/cost-report.sh [subscription_id]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require az jq
require_az_login

SUB="${1:-$(az account show --query id -o tsv)}"
[[ "${SUB}" =~ ^[0-9a-fA-F-]{36}$ ]] || die "invalid subscription id '${SUB}'"

body='{
  "type": "ActualCost",
  "timeframe": "MonthToDate",
  "dataset": {
    "granularity": "None",
    "aggregation": { "totalCost": { "name": "Cost", "function": "Sum" } },
    "grouping": [ { "type": "Dimension", "name": "ServiceName" } ]
  }
}'

result="$(az rest --method post \
  --url "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body "${body}" -o json)"

jq -r '
  (.properties.columns | map(.name)) as $cols
  | ($cols | index("Cost")) as $c
  | ($cols | index("ServiceName")) as $s
  | ($cols | index("Currency")) as $cur
  | .properties.rows
  | sort_by(-.[$c])
  | (map(.[$c]) | add // 0) as $total
  | (.[0][$cur] // "") as $currency
  | (map("\(.[$s] | .[0:40] | . + (" " * (42 - length)))\(.[$c] * 100 | round / 100)") | .[]),
    "------------------------------------------",
    "TOTAL (month to date)                     \($total * 100 | round / 100) \($currency)"
' <<<"${result}"
