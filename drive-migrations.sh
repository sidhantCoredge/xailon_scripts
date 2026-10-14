#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Drive the OpenMeter migrations to completion — one at a time, with no race
#
#   ./drive-migrations.sh
#
# What was happening: 4 deployments plus 3 CronJobs all run migrations on start.
# golang-migrate takes an advisory lock — one wins, marks dirty=true and applies
# the SQL, the rest exit(1) immediately. The result is that the version advances
# one step at a time and dirty stays stuck.
#
# This script shuts EVERYTHING down first (CronJobs suspended too), then steps
# through: clear dirty -> ONE pod only -> check the version -> repeat. When the
# version stops changing and dirty stays false, the migrations are complete.
#
# svix stays up — openmeter-api calls it during startup.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
NS="${NS:-openmeter}"
MAX="${MAX:-25}"
MIGRATORS="openmeter-api openmeter-balance-worker openmeter-billing-worker openmeter-notification-service openmeter-sink-worker"

PW="$(az keyvault secret show --vault-name "$VAULT" -n openmeter-db-password --query value -o tsv 2>/dev/null)"
[[ -n "$PW" ]] || { echo "could not read openmeter-db-password from Key Vault"; exit 1; }
q() { PGPASSWORD="$PW" psql -h "$PGHOST" -U openmeter -d openmeter -v ON_ERROR_STOP=1 -tAc "$1"; }
ver()   { q "select version from schema_om"; }
dirty() { q "select dirty from schema_om"; }

echo "=== 0. svix up (api calls it during startup) ==="
kubectl -n "$NS" scale deploy openmeter-svix --replicas=1 >/dev/null 2>&1 || true
kubectl -n "$NS" rollout status deploy/openmeter-svix --timeout=180s 2>/dev/null | tail -1

echo
echo "=== 1. shut down everything that runs migrations ==="
kubectl -n "$NS" scale deploy $MIGRATORS --replicas=0 >/dev/null
# the CronJobs run migrations too — suspend them or they will interleave
for cj in $(kubectl -n "$NS" get cronjob -o name 2>/dev/null); do
  kubectl -n "$NS" patch "$cj" -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
done
kubectl -n "$NS" delete job --all --wait=false >/dev/null 2>&1 || true
for i in $(seq 1 30); do
  n=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -E "openmeter-(api|balance|billing|notification|sink|subscription)" | grep -vc Completed || true)
  [[ "${n:-0}" -eq 0 ]] && break
  sleep 3
done
echo "  cronjobs suspended, migrator pods: $(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -E "openmeter-(api|balance|billing|notification|sink)" | grep -vc Completed || echo 0)"

echo
echo "=== 2. step by step ==="
LAST=""
for step in $(seq 1 "$MAX"); do
  V=$(ver); D=$(dirty)
  printf "  [%02d] version=%s dirty=%s" "$step" "$V" "$D"

  if [[ "$D" == "f" && -n "$LAST" && "$V" == "$LAST" ]]; then
    echo "  <- the version stopped and dirty is clear: migrations COMPLETE"
    break
  fi
  LAST="$V"
  [[ "$D" == "t" ]] && q "update schema_om set dirty=false" >/dev/null

  # one pod only, one run
  kubectl -n "$NS" scale deploy openmeter-api --replicas=1 >/dev/null
  sleep 25
  kubectl -n "$NS" scale deploy openmeter-api --replicas=0 >/dev/null
  for i in $(seq 1 20); do
    kubectl -n "$NS" get pods -l app.kubernetes.io/component=api --no-headers 2>/dev/null | grep -qv Completed || break
    sleep 2
  done
  NV=$(ver)
  if [[ "$NV" == "$V" ]]; then echo "  -> did not advance ($NV)"; else echo "  -> $NV"; fi
done

echo
echo "=== 3. final state ==="
echo "  version=$(ver) dirty=$(dirty)"
if [[ "$(dirty)" == "t" ]]; then
  echo "  !! still dirty. This is where it is stuck — to see the real error:"
  echo "     ./catch-migration-error.sh"
  exit 1
fi

echo
echo "=== 4. bring everything back up ==="
for cj in $(kubectl -n "$NS" get cronjob -o name 2>/dev/null); do
  kubectl -n "$NS" patch "$cj" -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
done
kubectl -n "$NS" scale deploy $MIGRATORS --replicas=1 >/dev/null
sleep 25
kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -v Completed | awk '{printf "  %-50s %s %s %s\n",$1,$2,$3,$4}'
