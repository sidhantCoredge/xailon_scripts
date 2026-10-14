#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Azure PostgreSQL — create the application roles (passwords from Key Vault)
#
#   ./pg-create-roles.sh --check   # reports status only, changes nothing
#   ./pg-create-roles.sh           # creates/updates the roles
#
# The databases already exist (Terraform created them) — this script only
# creates the ROLES and sets ownership. No password is typed by hand: every one
# is read from Key Vault, the same values the syncer puts in the k8s Secret.
#
# The openfga role is DELIBERATELY absent: the chart runs OpenFGA with
# `--datastore-engine=memory` (same as production). The `openfga` database
# exists but nothing uses it yet.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
PGADMIN="${PGADMIN:-pgadmintf}"
MODE="${1:-}"

# role : KV secret : database
MAP=(
  "tokenfactory:db-password:tokenfactory"
  "keycloak:kc-db-password:keycloak"
  "openmeter:openmeter-db-password:openmeter"
  "svix:svix-db-password:svix"
)

kv_get()  { az keyvault secret show --vault-name "$VAULT" -n "$1" --query value -o tsv 2>/dev/null; }
kv_has()  { az keyvault secret show --vault-name "$VAULT" -n "$1" >/dev/null 2>&1; }
rand()    { openssl rand -base64 48 | tr -d '/+=\n' | head -c 32; }

ADMIN_PW="$(kv_get pg-admin-password)"
[[ -n "$ADMIN_PW" ]] || { echo "could not read pg-admin-password from Key Vault"; exit 1; }

# every psql call: as the admin, SSL required (Azure Flexible Server)
q() { PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d "${2:-postgres}" \
        --set=sslmode=require -v ON_ERROR_STOP=1 -tAc "$1"; }

echo "Host  : $PGHOST"
echo "Admin : $PGADMIN"
echo

echo "-- connectivity --"
echo "  server: $(q 'select version()' | cut -c1-40)"
echo

echo "-- existing databases --"
q "select datname from pg_database where datname not like 'azure%' and datname not in ('postgres','template0','template1') order by 1" | sed 's/^/   /'
echo

echo "-- roles --"
declare -a TODO=()
for e in "${MAP[@]}"; do
  IFS=: read -r role key db <<< "$e"
  exists=$(q "select 1 from pg_roles where rolname='$role'")
  inkv=$(kv_has "$key" && echo yes || echo no)
  printf "   %-14s db=%-12s kv=%-26s role=%s\n" \
    "$role" "$db" "$key($inkv)" "${exists:+PRESENT}${exists:-ABSENT}"
  TODO+=("$e")
done

if [[ "$MODE" == "--check" ]]; then echo; echo "(--check only, nothing changed)"; exit 0; fi

echo
for e in "${TODO[@]}"; do
  IFS=: read -r role key db <<< "$e"

  # if the password is not in KV yet, create it (openmeter/svix on first run)
  if ! kv_has "$key"; then
    az keyvault secret set --vault-name "$VAULT" -n "$key" --value "$(rand)" -o none
    echo "  KV: created $key"
  fi
  PW="$(kv_get "$key")"
  [[ -n "$PW" ]] || { echo "  !! $key is empty, skipping $role"; continue; }

  # CREATE or ALTER — either way the password ends up being the KV value.
  # :'pw' is psql's own quoting, so special characters are safe.
  # NOTE: psql -c does NOT interpolate variables — :'pw' only works in SQL read
  # from stdin or -f. Hence the heredoc rather than -c.
  if [[ -n "$(q "select 1 from pg_roles where rolname='$role'")" ]]; then
    PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d postgres -v ON_ERROR_STOP=1 -q \
      -v pw="$PW" <<EOF
ALTER ROLE $role WITH LOGIN PASSWORD :'pw';
EOF
    echo "  $role: password synced from Key Vault"
  else
    PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d postgres -v ON_ERROR_STOP=1 -q \
      -v pw="$PW" <<EOF
CREATE ROLE $role WITH LOGIN PASSWORD :'pw';
EOF
    echo "  $role: created"
  fi

  # Ownership. On Azure, pgadmintf is NOT a superuser — to change a database's
  # owner it must be a member of that role, hence the GRANT first.
  PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d postgres -v ON_ERROR_STOP=1 -q <<EOF
GRANT $role TO $PGADMIN;
ALTER DATABASE $db OWNER TO $role;
GRANT ALL PRIVILEGES ON DATABASE $db TO $role;
EOF

  # On PG 15+ the `public` schema is NOT writable by a non-owner.
  # Skip this and migrations die on "permission denied for schema public".
  PGPASSWORD="$ADMIN_PW" psql -h "$PGHOST" -U "$PGADMIN" -d "$db" -v ON_ERROR_STOP=1 -q <<EOF
ALTER SCHEMA public OWNER TO $role;
GRANT ALL ON SCHEMA public TO $role;
EOF
  echo "  $role: owner of $db and of schema public"
done

echo
echo "-- verify: can each role log in to its own database? --"
for e in "${MAP[@]}"; do
  IFS=: read -r role key db <<< "$e"
  PW="$(kv_get "$key")"
  if [[ -z "$PW" ]]; then printf "   %-14s SKIP (empty in KV)\n" "$role"; continue; fi
  if out=$(PGPASSWORD="$PW" psql -h "$PGHOST" -U "$role" -d "$db" -v ON_ERROR_STOP=1 -tAc \
             "select current_user||'@'||current_database()" 2>&1); then
    printf "   %-14s OK   %s\n" "$role" "$out"
  else
    printf "   %-14s FAIL %s\n" "$role" "$(echo "$out" | tail -1)"
  fi
done
