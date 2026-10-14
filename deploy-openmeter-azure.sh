#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenMeter — deploy on Azure (xalion)
#
#   ./deploy-openmeter-azure.sh --check   # reports status only
#   ./deploy-openmeter-azure.sh           # deploys
#   DRY_RUN=1 ./deploy-openmeter-azure.sh # prints the commands, runs nothing
#
# This does not run helm itself — it calls the repo's own
# `helm/setup/scripts/deploy-openmeter.sh`. That is the maintained path and it
# carries two things that get forgotten when the command is typed by hand:
#   --post-renderer openmeter/postrender/postrender.sh  (patches the startup
#       probes onto the ClickHouse and busybox poller containers)
#   --wait --timeout 20m  (ClickHouse comes from an Altinity CR that --wait does
#       not track; at the 5m default the release fails and the hooks never run)
#
# Its own job is only this: fetch three secrets from Key Vault, build a TEMPORARY
# values file, and pass it as VALUES_FILE. No secret goes into git; the temp file
# is created mode 600 and is removed on exit.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
PGHOST="${PGHOST:-psql-tokenfactory.postgres.database.azure.com}"
APP_NAMESPACE="${APP_NAMESPACE:-xailon-tf-prod}"
OPENMETER_NS="${OPENMETER_NS:-openmeter}"
REPO="${REPO:-$HOME/xalion_7oct/ai-gateway-platform}"
BASE_VALUES="${BASE_VALUES:-$(cd "$(dirname "$0")" && pwd)/openmeter-azure-values.yaml}"
MODE="${1:-}"

RUNNER="$REPO/helm/setup/scripts/deploy-openmeter.sh"

have() { az keyvault secret show --vault-name "$VAULT" -n "$1" >/dev/null 2>&1; }
get()  { az keyvault secret show --vault-name "$VAULT" -n "$1" --query value -o tsv 2>/dev/null; }
rand() { openssl rand -base64 48 | tr -d '/+=\n' | head -c 32; }

echo "Vault     : $VAULT"
echo "PG host   : $PGHOST"
echo "OM ns     : $OPENMETER_NS   (app ns: $APP_NAMESPACE)"
echo "Runner    : $RUNNER"
echo "Base vals : $BASE_VALUES"
echo

[[ -f "$RUNNER"      ]] || { echo "repo script not found: $RUNNER"; exit 1; }
[[ -f "$BASE_VALUES" ]] || { echo "values file not found: $BASE_VALUES"; exit 1; }

# ── Key Vault ───────────────────────────────────────────────────────────────
for s in openmeter-db-password svix-db-password eventhub-connection-string; do
  if have "$s"; then
    echo "  $s  present"
  elif [[ "$MODE" == "--check" ]]; then
    echo "  $s  MISSING"
  elif [[ "$s" == "eventhub-connection-string" ]]; then
    echo "  $s  MISSING — cannot be generated, it comes from Event Hubs:"
    echo "    CS=\$(az eventhubs namespace authorization-rule keys list -g rg-tokenfactory \\"
    echo "           --namespace-name ehns-tokenfactory --name openmeter-app \\"
    echo "           --query primaryConnectionString -o tsv)"
    echo "    az keyvault secret set --vault-name $VAULT -n eventhub-connection-string --value \"\$CS\""
    exit 1
  else
    az keyvault secret set --vault-name "$VAULT" -n "$s" --value "$(rand)" -o none
    echo "  $s  CREATED"
  fi
done

if [[ "$MODE" == "--check" ]]; then echo; echo "(--check only, nothing changed)"; exit 0; fi

OM_PW=$(get openmeter-db-password)
SV_PW=$(get svix-db-password)
EH_CS=$(get eventhub-connection-string)
[[ -n "$OM_PW" && -n "$SV_PW" && -n "$EH_CS" ]] || { echo "could not read the values from Key Vault"; exit 1; }

# ── temporary values file ───────────────────────────────────────────────────
TMPD=$(mktemp -d); chmod 700 "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
VF="$TMPD/openmeter-values.yaml"

OM_DSN="postgres://openmeter:${OM_PW}@${PGHOST}:5432/openmeter?sslmode=require" \
SV_DSN="postgres://svix:${SV_PW}@${PGHOST}:5432/svix?sslmode=require" \
EH_CS="$EH_CS" BASE="$BASE_VALUES" OUT="$VF" python3 - <<'PY'
import os
# YAML single-quoted scalar: an inner ' is doubled. That keeps the connection
# string's = ; / and the DSN's @ ? all safe — no shell quoting involved.
def q(v): return "'" + v.replace("'", "''") + "'"
subs = [
    ('url: ""',          'url: ' + q(os.environ['OM_DSN'])),
    ('dsn: ""',          'dsn: ' + q(os.environ['SV_DSN'])),
    ('saslPassword: ""', 'saslPassword: ' + q(os.environ['EH_CS'])),
]
out, hits = [], {k: 0 for k, _ in subs}
for line in open(os.environ['BASE']):
    for old, new in subs:
        if line.lstrip().startswith(old):
            indent = line[:len(line) - len(line.lstrip())]
            line = indent + new + "\n"
            hits[old] += 1
            break
    out.append(line)
# if a placeholder is not found, do not silently deploy without the secret
assert hits['url: ""'] == 1,          f"postgres url placeholder: {hits}"
assert hits['dsn: ""'] == 1,          f"svix dsn placeholder: {hits}"
assert hits['saslPassword: ""'] == 2, f"sasl placeholders: {hits}"
open(os.environ['OUT'], 'w').writelines(out)
print("  values file written (3 secrets filled into 4 places)")
PY
chmod 600 "$VF"

# ── run the repo's script ───────────────────────────────────────────────────
echo
echo "-- the repo's deploy-openmeter.sh (it carries the post-renderer and the 20m timeout) --"
cd "$REPO"
OPENMETER_NS="$OPENMETER_NS" APP_NAMESPACE="$APP_NAMESPACE" VALUES_FILE="$VF" \
  FORCE_INSTALL="${FORCE_INSTALL:-1}" DRY_RUN="${DRY_RUN:-0}" \
  bash "$RUNNER"

[[ "${DRY_RUN:-0}" == "1" ]] && exit 0

echo
echo "-- is Kafka on Event Hubs? (there should be no bundled kafka) --"
if kubectl -n "$OPENMETER_NS" get sts 2>/dev/null | grep -qi kafka; then
  echo "   !! bundled kafka is running — kafka.enabled was not set to false"
else
  echo "   OK — no bundled kafka"
fi

echo
echo "-- the service (this is the name tf-ledger looks for) --"
kubectl -n "$OPENMETER_NS" get svc openmeter-api -o wide 2>/dev/null
echo
echo "URL the application expects: http://openmeter-api.${OPENMETER_NS}.svc.cluster.local"
