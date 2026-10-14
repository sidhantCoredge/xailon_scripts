#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Rebuild the tokenfactory database cleanly and run the migrations CORRECTLY
#
#   ./rebuild-tf-db.sh --check    # status only
#   ./rebuild-tf-db.sh            # DROP + CREATE + serialized migrations
#
# WHY: the previous attempt set `dirty=false` every time. In golang-migrate that
# marks the migration as "already applied" — the SQL never runs and the version
# advances anyway. That is how 5, 6, 7, 13, 14, 15, 16, 19, 21, 25, 28 and 30 got
# SKIPPED, and why tables like `tf_credit_grants` (migration 5) were never
# created. The correct recovery is `force <N-1>`, not clearing the flag.
#
# The ROOT CAUSE was probably the race: tf-accounts/tf-auth/tf-ledger at 3
# replicas each = 9 pods all running migrations at once, Kubernetes restarting
# the failing ones, and whichever pod holds the lock dying mid-way. This script
# runs ONLY ONE replica at a time.
#
# This script NEVER clears the dirty flag. If dirty appears it STOPS and shows
# the real error — because at that point it is a genuine failure, not a race.
#
# It does not touch the Keycloak database (separate DB, Liquibase, already complete).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
PGADMIN="${PGADMIN:-pgadmintf}"
NS="${NS:-xailon-tf-prod}"
DB=tokenfactory
ROLE=tokenfactory
MIGRATORS="tf-accounts tf-auth tf-ledger"
REPLICAS="${REPLICAS:-1}"
MODE="${1:-}"

APW="$(az keyvault secret show --vault-name "$VAULT" -n pg-admin-password --query value -o tsv 2>/dev/null)"
PW="$(az keyvault secret show --vault-name "$VAULT" -n db-password --query value -o tsv 2>/dev/null)"
[[ -n "$APW" && -n "$PW" ]] || { echo "could not read the passwords from Key Vault"; exit 1; }
# NOTE: the database is the FIRST argument. This used to read ${2:-postgres}
# while the call site was `adm "$DB"` — so ALTER SCHEMA was running against the
# `postgres` database, not the new tokenfactory one. The result was that the
# public schema stayed owned by pgadmintf and the migration died on
# "permission denied for schema public".
adm() { PGPASSWORD="$APW" psql -h "$PGHOST" -U "$PGADMIN" -d "${1:-postgres}" -v ON_ERROR_STOP=1 -q; }
q()   { PGPASSWORD="$PW"  psql -h "$PGHOST" -U "$ROLE" -d "$DB" -tAc "$1" 2>/dev/null; }

status() {
  echo "  tables : $(q "select count(*) from information_schema.tables where table_schema='public'")"
  for t in platform_schema_migrations tf_ledger_schema_migrations; do
    printf "  %-30s %s\n" "$t" "$(q "select version||' dirty='||dirty from $t" || echo '(absent)')"
  done
  echo "  tf_credit_grants present: $(q "select count(*) from information_schema.tables where table_name='tf_credit_grants'")"
}

echo "=== current state ==="; status
[[ "$MODE" == "--check" ]] && { echo; echo "(--check only, nothing changed)"; exit 0; }

ROWS=$(q "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables")
echo
echo "  live rows in the database: ${ROWS:-0}"
if [[ "${ROWS:-0}" -gt 50 ]]; then
  echo "  !! that many rows does not look like an empty environment. Stopping."
  echo "     To proceed deliberately: FORCE_DROP=1 $0"
  [[ "${FORCE_DROP:-0}" == "1" ]] || exit 1
fi
read -rp "  DROP and recreate the $DB database? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "stopped."; exit 0; }

echo
echo "=== 1. all three migrators to 0 (ends the race) ==="
kubectl -n "$NS" scale deploy $MIGRATORS --replicas=0 >/dev/null
for i in $(seq 1 40); do
  n=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -cE "^(tf-accounts|tf-auth|tf-ledger)-" || true)
  [[ "${n:-0}" -eq 0 ]] && break
  sleep 3
done
echo "  pods remaining: $(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -cE '^(tf-accounts|tf-auth|tf-ledger)-' || echo 0)"

echo
echo "=== 2. fresh $DB database ==="
adm <<EOF
GRANT $ROLE TO $PGADMIN;
DROP DATABASE IF EXISTS $DB WITH (FORCE);
CREATE DATABASE $DB OWNER $ROLE;
EOF
adm "$DB" <<EOF
ALTER SCHEMA public OWNER TO $ROLE;
GRANT ALL ON SCHEMA public TO $ROLE;
EOF
echo "  created, owner $ROLE"

echo
echo "=== 3. one service at a time, ONLY 1 replica, without touching the flag ==="
for svc in $MIGRATORS; do
  echo "  --- $svc ---"
  kubectl -n "$NS" scale deploy "$svc" --replicas=1 >/dev/null
  OK=0
  for i in $(seq 1 100); do
    L=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep "^${svc}-" | head -1)
    R=$(echo "$L" | awk '{print $2}'); S=$(echo "$L" | awk '{print $3}')
    [[ "$R" == "1/1" ]] && { OK=1; break; }
    case "$S" in *CrashLoopBackOff*) break ;; esac
    sleep 3
  done
  if [[ "$OK" == "1" ]]; then
    echo "    $svc READY"
  else
    echo "    !! $svc did not become ready ($S). NOT clearing the flag — this is a real failure."
    echo "    migration state:"; status
    echo "    logs:"
    kubectl -n "$NS" logs -l app.kubernetes.io/name="$svc" --all-containers --tail=30 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' | grep -iE "error|fatal|migrat" | tail -5 | cut -c1-200
    echo
    echo "    If you see 'Dirty database version N', the CORRECT recovery is (do NOT clear the flag):"
    echo "      migrate ... force \$((N-1))   then run again — migration N's SQL will re-run."
    exit 1
  fi
done

echo
echo "=== 4. final state ==="; status
echo
echo "=== 5. everything back to $REPLICAS replicas ==="
kubectl -n "$NS" scale deploy $MIGRATORS --replicas="$REPLICAS" >/dev/null
sleep 30
kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -vE "1/1 *Running|2/2 *Running|Completed" | awk '{printf "  %-50s %s %s %s\n",$1,$2,$3,$4}' || echo "  all Running"
