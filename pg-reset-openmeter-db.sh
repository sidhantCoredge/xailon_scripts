#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Drop and recreate the openmeter database (the fix for a dirty migration)
#
#   ./pg-reset-openmeter-db.sh --check   # reports status only
#   ./pg-reset-openmeter-db.sh           # performs DROP + CREATE
#
# WHEN you need this: an OpenMeter migration broke part-way through and left
# dirty=t in `schema_om` —
#   failed to migrate db: Dirty database version <N>. Fix and force version.
#
# Why DROP rather than just clearing the dirty flag: clearing it re-runs the
# same migration that already applied half of its statements, which then dies
# on "relation already exists". This is a new environment with zero data, so a
# clean slate is the most direct route.
#
# THIS IS DESTRUCTIVE. The script counts the data first and STOPS BY ITSELF if
# the count is not zero.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
PGADMIN="${PGADMIN:-pgadmintf}"
DB="${DB:-openmeter}"
ROLE="${ROLE:-openmeter}"
NS="${NS:-openmeter}"
MODE="${1:-}"

ADMIN_PW="$(az keyvault secret show --vault-name "$VAULT" -n pg-admin-password --query value -o tsv 2>/dev/null)"
[[ -n "$ADMIN_PW" ]] || { echo "could not read pg-admin-password from Key Vault"; exit 1; }
q() { PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d "${2:-postgres}" -v ON_ERROR_STOP=1 -tAc "$1"; }

echo "Host : $PGHOST"
echo "DB   : $DB (owner $ROLE)"
echo

DIRTY=$(q "select version||' dirty='||dirty from schema_om" "$DB" 2>/dev/null || echo "(schema_om not found)")
ROWS=$(q "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables" "$DB" 2>/dev/null || echo 0)
TBLS=$(q "select count(*) from information_schema.tables where table_schema='public'" "$DB" 2>/dev/null || echo 0)
echo "  migration : $DIRTY"
echo "  tables    : $TBLS"
echo "  live rows : $ROWS   (schema_om's own marker row is counted here)"

if [[ "$MODE" == "--check" ]]; then echo; echo "(--check only, nothing changed)"; exit 0; fi

# Safety: only schema_om's marker should be there. More than that means real
# data, so stop.
if [[ "${ROWS:-0}" -gt 1 ]]; then
  echo
  echo "!! found $ROWS rows — this is not an empty database. Doing nothing."
  echo "   To proceed deliberately: FORCE_DROP=1 $0"
  [[ "${FORCE_DROP:-0}" == "1" ]] || exit 1
fi

echo
echo "-- scale the openmeter workloads to 0 (otherwise a crashloop keeps reconnecting) --"
kubectl -n "$NS" scale deploy -l app.kubernetes.io/name=openmeter --replicas=0 2>/dev/null || true

echo
echo "-- DROP + CREATE --"
# WITH (FORCE) drops the remaining connections (PG 13+). The admin must be a
# member of the role before it can create a database owned by it.
PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d postgres -v ON_ERROR_STOP=1 -q <<EOF
GRANT $ROLE TO $PGADMIN;
DROP DATABASE IF EXISTS $DB WITH (FORCE);
CREATE DATABASE $DB OWNER $ROLE;
EOF
# On PG 15+ the public schema is not writable by a non-owner — migrations die
# on "permission denied for schema public" if this is skipped.
PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d "$DB" -v ON_ERROR_STOP=1 -q <<EOF
ALTER SCHEMA public OWNER TO $ROLE;
GRANT ALL ON SCHEMA public TO $ROLE;
EOF
echo "  $DB recreated, owner $ROLE"

echo
echo "-- scale the workloads back up --"
kubectl -n "$NS" scale deploy -l app.kubernetes.io/name=openmeter --replicas=1 2>/dev/null || true

echo
echo "-- waiting for the migration to run from scratch (openmeter-api) --"
kubectl -n "$NS" rollout status deploy/openmeter-api --timeout=300s 2>/dev/null || {
  echo "  not ready yet. Logs:"
  kubectl -n "$NS" logs deploy/openmeter-api --tail=15 2>/dev/null | grep -iE "error|migrat" | cut -c1-200 | tail -5
}
echo
kubectl -n "$NS" get pods --no-headers 2>/dev/null
