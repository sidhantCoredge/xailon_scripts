#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Capture the real migration error
#
#   ./catch-migration-error.sh
#
# The problem: every pod that sees dirty=true exits(1) within a second and logs
# only "Dirty database version ...". The run that actually executed the SQL and
# produced the real error scrolls out of the logs (only --previous reaches it).
#
# This script clears dirty, immediately recreates the pod, captures the FULL log
# of that ONE run, and then extracts the real cause from it. Each run advances
# one migration, so run it again if needed.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
NS="${NS:-openmeter}"
DEP="${DEP:-openmeter-api}"
OUT="${OUT:-/tmp/openmeter-migration-$(date +%H%M%S).log}"

PW="$(az keyvault secret show --vault-name "$VAULT" -n openmeter-db-password --query value -o tsv 2>/dev/null)"
[[ -n "$PW" ]] || { echo "could not read openmeter-db-password from Key Vault"; exit 1; }
q() { PGPASSWORD="$PW" psql -h "$PGHOST" -U openmeter -d openmeter -v ON_ERROR_STOP=1 -tAc "$1"; }

echo "before : $(q "select version||' dirty='||dirty from schema_om")"
q "update schema_om set dirty = false" >/dev/null
echo "clear : $(q "select version||' dirty='||dirty from schema_om")"

echo
echo "-- recreating the pod and capturing its log --"
kubectl -n "$NS" delete pod -l app.kubernetes.io/component=api --wait=false >/dev/null 2>&1 || true

# wait for the new pod
POD=""
for i in $(seq 1 40); do
  POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=api \
        --field-selector=status.phase!=Succeeded -o name 2>/dev/null | head -1)
  [[ -n "$POD" ]] && kubectl -n "$NS" get "$POD" -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null | grep -q true && break
  sleep 2
done
echo "  pod: ${POD:-<not found>}"

# the full log of a single run — follow ends as soon as the container dies
kubectl -n "$NS" logs "$POD" -f --tail=-1 > "$OUT" 2>/dev/null || true
echo "  log: $OUT  ($(wc -l < "$OUT") lines)"

echo
echo "=== REAL ERROR ==="
grep -o '"error.message":"[^"]*"' "$OUT" | grep -viE "didn.t run yet" | tail -3 | fold -w 180
echo
echo "=== any SQL/permission hint related to the migration ==="
grep -ioE "(permission denied[^\"]*|does not exist[^\"]*|already exists[^\"]*|not allow-listed[^\"]*|extension [^\"]*|SQLSTATE[^\"]*)" "$OUT" | sort -u | head -8
echo
echo "after  : $(q "select version||' dirty='||dirty from schema_om")"
echo "(full log: $OUT)"
