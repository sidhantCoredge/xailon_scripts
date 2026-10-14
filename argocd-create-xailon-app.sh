#!/usr/bin/env bash
# Creates the xalion Application in Argo CD.
#
#   1. reads the repo credential (GitHub PAT) from Key Vault into a Secret in the argocd namespace
#   2. the `xailon-tokenfactory` Application — manual sync, no auto-sync
#
# The PAT never goes into git; it is read from Key Vault every time.
# This does NOT sync — you do that yourself from the Argo UI.
set -euo pipefail

KV=${KV:-kv-tokenfactory}
REPO="https://github.com/Infinia-Technology/ai-gateway-platform.git"
APP_FILE="$(dirname "$0")/argocd-app-xailon-tokenfactory.yaml"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "1/4  GitHub credential from Key Vault"
GH_USER=$(az keyvault secret show --vault-name "$KV" -n ghcr-user --query value -o tsv)
GH_PAT=$(az keyvault secret show  --vault-name "$KV" -n ghcr-pat  --query value -o tsv)
[ -n "$GH_USER" ] && [ -n "$GH_PAT" ] || { echo "could not read the credential from Key Vault"; exit 1; }
echo "   user: $GH_USER   pat: ${#GH_PAT} chars"

say "2/4  can the PAT read the repo? (catch it here, before Argo does)"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
printf '#!/bin/sh\ncase "$1" in *Username*) echo "$GU";; *Password*) echo "$GP";; esac\n' > "$D/ask"
chmod +x "$D/ask"
GU="$GH_USER" GP="$GH_PAT" GIT_ASKPASS="$D/ask" GIT_TERMINAL_PROMPT=0 \
  git ls-remote --heads "$REPO" main | sed 's/^/   /'

say "3/4  repository Secret in the argocd namespace"
kubectl create secret generic xalion-repo-ai-gateway-platform \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url="$REPO" \
  --from-literal=username="$GH_USER" \
  --from-literal=password="$GH_PAT" \
  --dry-run=client -o yaml \
 | kubectl label --local -f - \
     argocd.argoproj.io/secret-type=repository -o yaml \
 | kubectl apply -f -

say "4/4  Application (manual sync)"
kubectl apply -f "$APP_FILE"

say "Result"
kubectl get application xailon-tokenfactory -n argocd \
  -o custom-columns=NAME:.metadata.name,REV:.spec.source.targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status
echo
echo "Now the Argo UI: https://argo.xailon.ai/applications/xailon-tokenfactory"
echo "Nothing syncs on its own — press 'Sync' in the UI when you want it."
echo "Press REFRESH first, then review 'App Diff' before you SYNC."
