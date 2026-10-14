#!/usr/bin/env bash
# TESTS PR #665's openmeter on xalion.
#   ./test-pr665.sh --dry      server-side dry-run (changes nothing)
#   ./test-pr665.sh            the real helm upgrade
#   ./test-pr665.sh --revert   back to our own openmeter
set -euo pipefail
VAULT=kv-tokenfactory
PGHOST=psql-tokenfactory.postgres.database.azure.com
OM_NS=openmeter
APP_NS=xailon-tf-prod
PR_CHART=$HOME/manish-openmeter/ai-gateway-platform/helm/infrastructure/openmeter
BASE=$HOME/xalion/openmeter-azure-values.yaml
MODE="${1:-}"

say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
get(){ az keyvault secret show --vault-name "$VAULT" -n "$1" --query value -o tsv 2>/dev/null; }

if [[ "$MODE" == "--revert" ]]; then
  say "back to our own openmeter"
  cd "$HOME/xalion" && APP_NAMESPACE="$APP_NS" ./deploy-openmeter-azure.sh
  exit 0
fi

say "3 secrets from Key Vault"
OM_PW=$(get openmeter-db-password); SV_PW=$(get svix-db-password); EH_CS=$(get eventhub-connection-string)
[[ -n "$OM_PW" && -n "$SV_PW" && -n "$EH_CS" ]] || { echo "could not read the values from Key Vault"; exit 1; }
echo "  retrieved"

TMPD=$(mktemp -d); chmod 700 "$TMPD"; trap 'rm -rf "$TMPD"' EXIT
VF="$TMPD/vals.yaml"
OM_DSN="postgres://openmeter:${OM_PW}@${PGHOST}:5432/openmeter?sslmode=require" \
SV_DSN="postgres://svix:${SV_PW}@${PGHOST}:5432/svix?sslmode=require" \
EH_CS="$EH_CS" BASE="$BASE" OUT="$VF" python3 - <<'PY'
import os
def q(v): return "'" + v.replace("'", "''") + "'"
subs=[('url: ""','url: '+q(os.environ['OM_DSN'])),
      ('dsn: ""','dsn: '+q(os.environ['SV_DSN'])),
      ('saslPassword: ""','saslPassword: '+q(os.environ['EH_CS']))]
out,hits=[],{k:0 for k,_ in subs}
for line in open(os.environ['BASE']):
    for old,new in subs:
        if line.lstrip().startswith(old):
            ind=line[:len(line)-len(line.lstrip())]; line=ind+new+"\n"; hits[old]+=1; break
    out.append(line)
assert hits['url: ""']==1 and hits['dsn: ""']==1 and hits['saslPassword: ""']==2, hits
open(os.environ['OUT'],'w').writelines(out)
print("  values file written")
PY
chmod 600 "$VF"

# The PR's new clickhouseCredentials password — from KV, created if absent
CH_PW=$(get clickhouse-app-password || true)
if [[ -z "$CH_PW" ]]; then
  CH_PW=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
  az keyvault secret set --vault-name "$VAULT" -n clickhouse-app-password --value "$CH_PW" -o none
  echo "  CREATED clickhouse-app-password in Key Vault"
fi

DRY=""; [[ "$MODE" == "--dry" ]] && DRY="--dry-run=server"
say "helm upgrade (PR #665's chart) ${DRY:+[DRY RUN]}"
set -x
helm upgrade openmeter "$PR_CHART" -n "$OM_NS" \
  -f "$VF" \
  --set openmeter.networkPolicy.appNamespace="$APP_NS" \
  --set openmeter.clickhouseCredentials.password="$CH_PW" \
  --post-renderer "$PR_CHART/postrender/postrender.sh" \
  --wait --timeout 20m $DRY
