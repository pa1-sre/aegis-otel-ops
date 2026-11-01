#!/usr/bin/env bash
# Smoke test for the Aegis observability pipeline.
# Sends one log (with an email), three traces and five metrics through the collector,
# then queries Loki, Tempo and Mimir directly. Run it after every boot.
# Uses its own local ports (14318, 13100, 13200, 18080) so it does not touch other port-forwards.
set -uo pipefail

NS=observability
ID=$(date +%s)
SVC="smoke-$ID"
TG=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.162.0
COLLECTOR="aegis-collector-collector.$NS.svc.cluster.local"
pass=0; fail=0

check() {  # check "<name>" ok|fail
  if [ "$2" = "ok" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi
}

kubectl port-forward -n "$NS" svc/aegis-collector-collector 14318:4318 >/dev/null 2>&1 &
kubectl port-forward -n "$NS" svc/loki 13100:3100 >/dev/null 2>&1 &
kubectl port-forward -n "$NS" svc/lgtm-tempo-query-frontend 13200:3200 >/dev/null 2>&1 &
kubectl port-forward -n "$NS" svc/lgtm-mimir-nginx 18080:80 >/dev/null 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null' EXIT
sleep 3

echo "== sending test data as service $SVC"

# 1. A log line that contains an email. The collector should mask it.
payload=$(cat <<EOF
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"$SVC"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"$(date +%s%N)","severityText":"INFO","body":{"stringValue":"smoke test for dave@example.com"}}]}]}]}
EOF
)
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST localhost:14318/v1/logs \
  -H 'Content-Type: application/json' -d "$payload")
check "collector accepted the log (HTTP $code)" "$([ "$code" = "200" ] && echo ok || echo fail)"

# 2. Three traces and 3. five metrics, from inside the cluster.
kubectl run "tg-t-$ID" -n "$NS" --rm -i --restart=Never --image="$TG" -- \
  traces --otlp-endpoint "$COLLECTOR:4317" --otlp-insecure --traces 3 --service "$SVC" >/dev/null 2>&1
kubectl run "tg-m-$ID" -n "$NS" --rm -i --restart=Never --image="$TG" -- \
  metrics --otlp-endpoint "$COLLECTOR:4317" --otlp-insecure --metrics 5 >/dev/null 2>&1

echo "== waiting 25s for batching and ingestion"
sleep 25

echo "== checking each backend directly"

# Loki: the line must be there, masked, and the raw email must not be.
logs=$(curl -sG localhost:13100/loki/api/v1/query_range \
  --data-urlencode "query={service_name=\"$SVC\"}" --data-urlencode 'since=10m')
echo "$logs" | grep -q 'REDACTED_EMAIL' && check "Loki has the masked log line" ok || check "Loki has the masked log line" fail
echo "$logs" | grep -q 'dave@example.com' && check "no raw email in Loki" fail || check "no raw email in Loki" ok

# Tempo: search by service name.
traces=$(curl -sG localhost:13200/api/search --data-urlencode "tags=service.name=$SVC")
echo "$traces" | grep -q "$SVC" && check "Tempo finds the test traces" ok || check "Tempo finds the test traces" fail

# Mimir: the metric name must appear in the list of stored names.
names=$(curl -sG localhost:18080/prometheus/api/v1/label/__name__/values)
echo "$names" | grep -q "smoke_$ID" && check "Mimir has the new metric" ok || check "Mimir has the new metric" fail

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
