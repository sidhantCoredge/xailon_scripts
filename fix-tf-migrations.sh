#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Run the tokenfactory migrations one at a time (the cure for the dirty flag)
#
#   ./fix-tf-migrations.sh --check
#   ./fix-tf-migrations.sh
#
# The `tokenfactory` database has TWO separate tracking tables:
#   platform_schema_migrations   -> tf-accounts and tf-auth (db-migrate initContainer)
#   tf_ledger_schema_migrations  -> tf-ledger (embedded, inside the main container)
#
# Each service runs 3 replicas and every one of them runs migrations on start.
# golang-migrate marks dirty FIRST and then applies the SQL — so if one dies
# mid-way the flag is left stuck, and all the others see it and exit. The real
# error is never logged anywhere.
#
# The cure: scale everything to 0, clear the flag, bring each service up at 1
# replica in turn, then restore all of them. Keycloak is left alone — it uses
# Liquibase and its database is already fine.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
NS="${NS:-xailon-tf-prod}"
MAX="${MAX:-25}"
# tf-auth waits for tf-accounts (wait-for-accounts init), hence this order
MIGRATORS="tf-accounts tf-auth tf-ledger"
REPLICAS="${REPLICAS:-3}"

PW="$(az keyvault secret show --vault-name "$VAULT" -n db-password --query value -o tsv 2>/dev/null)"
[[ -n "$PW" ]] || { echo "could not read db-password from Key Vault"; exit 1; }
q() { PGPASSWORD="$PW" psql -h "$PGHOST" -U tokenfactory -d tokenfactory -v ON_ERROR_STOP=1 -tAc "$1"; }
st() { for t in platform_schema_migrations tf_ledger_schema_migrations; do
         printf "  %-30s %s\n" "$t" "$(q "select 'version='||version||' dirty='||dirty from $t" 2>/dev/null || echo '(no table)')"
       done; }

echo "=== current state ==="; st
echo "  advisory locks: $(q "select count(*) from pg_locks where locktype='advisory'")"
[[ "${1:-}" == "--check" ]] && { echo; echo "(--check only, nothing changed)"; exit 0; }

echo
echo "=== 1. all three migrators to 0 ==="
kubectl -n "$NS" scale deploy $MIGRATORS --replicas=0 >/dev/null
for i in $(seq 1 40); do
  n=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -E "^(tf-accounts|tf-auth|tf-ledger)-" | grep -vc Completed || true)
  [[ "${n:-0}" -eq 0 ]] && break
  sleep 3
done
echo "  pods remaining: $(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -cE "^(tf-accounts|tf-auth|tf-ledger)-" || echo 0)"

echo
echo "=== 2. each service in turn, at 1 replica ==="
for svc in $MIGRATORS; do
  echo
  echo "  --- $svc ---"
  LAST=""
  for step in $(seq 1 "$MAX"); do
    # clear both flags — which table belongs to which service varies
    for t in platform_schema_migrations tf_ledger_schema_migrations; do
      q "update $t set dirty=false where dirty" >/dev/null 2>&1 || true
    done
    V=$(q "select string_agg(v,'/') from (select version::text v from platform_schema_migrations union all select version::text from tf_ledger_schema_migrations) x" 2>/dev/null || echo "?")
    printf "    [%02d] versions=%s" "$step" "$V"

    kubectl -n "$NS" scale deploy "$svc" --replicas=1 >/dev/null
    # Do NOT wait on `rollout status --timeout=180s`: the pod fails in about 5
    # seconds but rollout status sits for the full 180s. Over 35 iterations that
    # is hours of difference. So poll every 3s and move on immediately.
    OK=0
    for w in $(seq 1 60); do
      PH=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep "^${svc}-" | head -1 | awk '{print $3}')
      RD=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep "^${svc}-" | head -1 | awk '{print $2}')
      case "$PH" in
        *Error*|*CrashLoopBackOff*|*BackOff*) break ;;
      esac
      [[ "$RD" == "1/1" ]] && { OK=1; break; }
      sleep 3
    done
    if [[ "$OK" == "1" ]]; then
      echo "  -> $svc READY"
      break
    fi
    kubectl -n "$NS" scale deploy "$svc" --replicas=0 >/dev/null
    for i in $(seq 1 20); do
      kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -q "^${svc}-" || break
      sleep 2
    done
    NV=$(q "select string_agg(v,'/') from (select version::text v from platform_schema_migrations union all select version::text from tf_ledger_schema_migrations) x" 2>/dev/null || echo "?")
    if [[ "$NV" == "$V" && "$V" == "$LAST" ]]; then
      echo "  -> did not advance ($NV) — this is where it is stuck"
      echo "     real error:"
      kubectl -n "$NS" logs -l app.kubernetes.io/name="$svc" --all-containers --tail=40 2>/dev/null \
        | grep -iE "error|fatal|dirty|migrat" | grep -viE "Dirty database version" | tail -4 | cut -c1-200
      break
    fi
    LAST="$V"; echo "  -> $NV"
  done
done

echo
echo "=== 3. final state ==="; st
# Whether every migration was reached — the repo has 15 for tf-accounts and 32
# for tf-ledger. A version short of those means something was skipped.
echo "  (tf-accounts has 15 migrations in total, tf-ledger 32 — the version should reach these)"
if q "select count(*) from (select 1 from platform_schema_migrations where dirty union all select 1 from tf_ledger_schema_migrations where dirty) x" | grep -q '^0$'; then
  echo
  echo "=== 4. everything back to $REPLICAS replicas ==="
  kubectl -n "$NS" scale deploy $MIGRATORS --replicas="$REPLICAS" >/dev/null
  sleep 25
  kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -vE "1/1 *Running|2/2 *Running|Completed" | awk '{printf "  %-52s %s %s %s\n",$1,$2,$3,$4}' || echo "  all Running"
else
  echo "  !! still dirty — see the 'real error' above"
  exit 1
fi
