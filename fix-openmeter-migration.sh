#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Run the OpenMeter migration ALONE (the real cure for the dirty flag)
#
#   ./fix-openmeter-migration.sh --check
#   ./fix-openmeter-migration.sh
#
# Root cause: api / balance-worker / billing-worker / notification-service all
# four run migrations on start. golang-migrate takes an advisory lock: one wins,
# marks `dirty=true` and applies the DDL, the other three exit(1) immediately on
# "Dirty database version ...". Three crash, go into CrashLoopBackOff, and the
# winner of the race dies too — leaving the dirty flag set. The real error is
# never logged, because migrate marks dirty FIRST.
#
# Hence: scale everything to 0, clear the flag, bring up ONE pod to finish the
# migration, then start the rest. Once that is done the race is harmless — the
# schema is already current.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
NS="${NS:-openmeter}"
LEAD="${LEAD:-openmeter-api}"
MODE="${1:-}"

PW="$(az keyvault secret show --vault-name "$VAULT" -n openmeter-db-password --query value -o tsv 2>/dev/null)"
[[ -n "$PW" ]] || { echo "could not read openmeter-db-password from Key Vault"; exit 1; }
q() { PGPASSWORD="$PW" psql -h "$PGHOST" -U openmeter -d openmeter -v ON_ERROR_STOP=1 -tAc "$1"; }

echo "=== current state ==="
echo "  migration : $(q "select version||' dirty='||dirty from schema_om" 2>/dev/null || echo '(no schema_om)')"
echo "  tables    : $(q "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null)"
echo "  active    : $(q "select count(*) from pg_locks where locktype='advisory'" 2>/dev/null) advisory lock"
[[ "$MODE" == "--check" ]] && { echo; echo "(--check only, nothing changed)"; exit 0; }

# Only the deployments that run MIGRATIONS. openmeter-svix is DELIBERATELY left
# out of this list: it does not run migrations, but openmeter-api calls it during
# startup (PUT /api/v1/event-type/...) and that happens BEFORE the migration.
# Scale Svix down and api hangs there — this has happened once already.
MIGRATORS="openmeter-api openmeter-balance-worker openmeter-billing-worker openmeter-notification-service openmeter-sink-worker"

echo
echo "=== 0. svix must be up (api calls it during startup) ==="
kubectl -n "$NS" scale deploy openmeter-svix --replicas=1 2>/dev/null || true
kubectl -n "$NS" rollout status deploy/openmeter-svix --timeout=180s 2>/dev/null || echo "  (svix did not become ready — api may hang)"

echo
echo "=== 1. migration-running workloads to 0 (to stop the race) ==="
kubectl -n "$NS" scale deploy $MIGRATORS --replicas=0
for i in $(seq 1 30); do
  n=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -E "openmeter-(api|balance|billing|notification|sink)" | grep -vc Completed || true)
  [[ "${n:-0}" -eq 0 ]] && break
  sleep 3
done
echo "  pods: $(kubectl -n "$NS" get pods -l app.kubernetes.io/name=openmeter --no-headers 2>/dev/null | grep -vc Completed || echo 0)"

echo
echo "=== 2. clear the dirty flag ==="
q "update schema_om set dirty = false" >/dev/null
echo "  now: $(q "select version||' dirty='||dirty from schema_om")"

echo
echo "=== 3. ONLY $LEAD up — the migration runs on its own ==="
kubectl -n "$NS" scale deploy "$LEAD" --replicas=1
if kubectl -n "$NS" rollout status deploy/"$LEAD" --timeout=600s; then
  echo "  $LEAD ready"
else
  echo "  !! $LEAD did not become ready. Real error (dirty will not hide it now):"
  kubectl -n "$NS" logs deploy/"$LEAD" --tail=200 2>/dev/null \
    | grep -o '"error.message":"[^"]*"' | tail -3
  echo "  migration: $(q "select version||' dirty='||dirty from schema_om")"
  exit 1
fi

echo
echo "=== 4. start the remaining workloads ==="
kubectl -n "$NS" scale deploy $MIGRATORS --replicas=1
sleep 15

echo
echo "=== 5. state ==="
echo "  migration : $(q "select version||' dirty='||dirty from schema_om")"
kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -v Completed | awk '{printf "  %-50s %s %s %s\n",$1,$2,$3,$4}'
