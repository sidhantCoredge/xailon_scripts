#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Clean OpenMeter reinstall: helm uninstall -> fresh databases -> helm install
#
#   ./reinstall-openmeter.sh
#
# Why the whole cycle: right now every pod says "Dirty database version ...",
# which hides the REAL migration error. With an empty database and a single
# fresh pod, the first run puts the real cause in the logs. This script extracts
# and displays that error for you.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
PGADMIN="${PGADMIN:-pgadmintf}"
NS="${NS:-openmeter}"
XDIR="$(cd "$(dirname "$0")" && pwd)"

ADMIN_PW="$(az keyvault secret show --vault-name "$VAULT" -n pg-admin-password --query value -o tsv 2>/dev/null)"
[[ -n "$ADMIN_PW" ]] || { echo "could not read pg-admin-password from Key Vault"; exit 1; }
psql_admin() { PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d "${1:-postgres}" -v ON_ERROR_STOP=1 -q; }

echo "== 1. helm uninstall =="
helm uninstall openmeter -n "$NS" --wait --timeout 5m 2>&1 | tail -2 || echo "  (no release existed, moving on)"

echo
echo "== 2. waiting for the pods to go away =="
for i in $(seq 1 30); do
  n=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -vcE "Completed|^$" || true)
  [[ "${n:-0}" -eq 0 ]] && break
  sleep 4
done
kubectl -n "$NS" get pods --no-headers 2>/dev/null | head -5 || echo "  (no pods)"

echo
echo "== 3. openmeter + svix databases from scratch =="
# Both, because they have separate migrations and either one may be half-applied.
psql_admin <<EOF
GRANT openmeter TO $PGADMIN;
GRANT svix      TO $PGADMIN;
DROP DATABASE IF EXISTS openmeter WITH (FORCE);
DROP DATABASE IF EXISTS svix      WITH (FORCE);
CREATE DATABASE openmeter OWNER openmeter;
CREATE DATABASE svix      OWNER svix;
EOF
# PG 15+ : the public schema is not writable by a non-owner
psql_admin openmeter <<EOF
ALTER SCHEMA public OWNER TO openmeter;
GRANT ALL ON SCHEMA public TO openmeter;
EOF
psql_admin svix <<EOF
ALTER SCHEMA public OWNER TO svix;
GRANT ALL ON SCHEMA public TO svix;
EOF
echo "  both databases empty, ownership set"

echo
echo "== 4. helm install =="
"$XDIR/deploy-openmeter-azure.sh" || true

echo
echo "== 5. the REAL migration error (the one hidden behind 'Dirty') =="
sleep 20
FOUND=0
for p in $(kubectl -n "$NS" get pods -o name 2>/dev/null | grep -E "api|balance|billing|notification"); do
  for f in "" "--previous"; do
    msg=$(kubectl -n "$NS" logs "$p" $f --tail=400 2>/dev/null \
          | grep -o '"error.message":"[^"]*"' \
          | grep -viE "Dirty database version|didn.t run yet" | tail -1 || true)
    if [[ -n "$msg" ]]; then echo "  $p  $msg"; FOUND=1; fi
  done
done
[[ "$FOUND" -eq 0 ]] && echo "  (no non-dirty error found — it may have worked)"

echo
echo "== 6. state =="
kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -v Completed | awk '{printf "  %-50s %s %s\n",$1,$2,$3}'
PW=$(az keyvault secret show --vault-name "$VAULT" -n openmeter-db-password --query value -o tsv 2>/dev/null)
echo "  migration: $(PGPASSWORD="$PW" psql -h "$PGHOST" -U openmeter -d openmeter -tAc "select version||' dirty='||dirty from schema_om" 2>/dev/null || echo '(schema_om does not exist yet)')"
