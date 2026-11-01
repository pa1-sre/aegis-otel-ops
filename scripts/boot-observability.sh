#!/usr/bin/env bash
set -euo pipefail
NS=observability

up()   { kubectl scale "$1" -n "$NS" --replicas=1 >/dev/null; }
wait_(){ echo "   waiting for $1"
         kubectl rollout status "$1" -n "$NS" --timeout=240s || {
           echo "!! $1 did not become ready. Pods:"
           kubectl get pods -n "$NS" | grep "${1#*/}"
           return 1; }; }
stage(){ local kind=$1; shift; echo "--> $kind: $*"
         for n in "$@"; do up "$kind/$n"; done
         for n in "$@"; do wait_ "$kind/$n"; done; }

if [ -z "${SKIP_STOP:-}" ]; then
echo "== 0. stop everything"
kubectl scale deploy,sts --all -n "$NS" --replicas=0
sleep 15
fi
echo "== 1. object storage"
stage deploy lgtm-minio

echo "== 2. stateful write path"
stage sts lgtm-mimir-ingester lgtm-tempo-ingester lgtm-tempo-memcached loki
stage sts lgtm-mimir-store-gateway lgtm-mimir-compactor

echo "== 3. distributors and compactors"
stage deploy lgtm-mimir-distributor lgtm-tempo-distributor lgtm-tempo-compactor lgtm-rollout-operator

echo "== 4. query layer"
stage deploy lgtm-mimir-querier lgtm-mimir-query-frontend lgtm-mimir-query-scheduler \
  lgtm-mimir-ruler lgtm-mimir-overrides-exporter lgtm-mimir-nginx \
  lgtm-tempo-querier lgtm-tempo-query-frontend
stage sts lgtm-mimir-alertmanager

echo "== 5. Grafana"
stage deploy lgtm-grafana

echo "== 6. collector (last, it exports to everything above)"
stage deploy aegis-collector-collector

echo "== done; anything not Running:"
kubectl get pods -n "$NS" --no-headers | grep -v -E 'Running|Completed' || echo "all healthy"
