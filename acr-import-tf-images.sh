#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Import the tf-* images from GHCR into ACR
#
#   TAG=0.16.1-b459501 ./acr-import-tf-images.sh --check    # report only
#   TAG=0.16.1-b459501 ./acr-import-tf-images.sh            # perform the import
#
# The GHCR packages are PRIVATE (anonymous pull returns 403), so credentials are
# required — a GitHub username plus a PAT carrying the `read:packages` scope.
#
# Where the PAT comes from: pass it once via the environment —
#   GHCR_USER=<github-username> GHCR_PAT=<pat> TAG=0.16.1-b459501 ./acr-import-tf-images.sh
# The script stores it in Key Vault as `ghcr-pat` / `ghcr-user` and reads it from
# there on subsequent runs (no need to paste it again).
#
# `az acr import` is SERVER-SIDE — the image does not pass through the jumphost,
# uses no local disk, and the firewall is not in the path. ACR pulls from GHCR
# itself.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
ACR="${ACR:-acrtokenfactory}"
SRC_REPO="${SRC_REPO:-ghcr.io/infinia-technology/ai-gateway-platform}"
DST_REPO="${DST_REPO:-infinia-technology/ai-gateway-platform}"
TAG="${TAG:?TAG is required, e.g. TAG=0.16.1-b459501}"
MODE="${1:-}"

SERVICES="tf-accounts tf-admin-web tf-auth tf-babel tf-control tf-docs-web
          tf-ledger tf-ops tf-portal-web tf-relay tf-shim tf-site-web tf-warden"

kv_get() { az keyvault secret show --vault-name "$VAULT" -n "$1" --query value -o tsv 2>/dev/null; }

# Credentials: if given in the environment, store them in KV; otherwise read from KV.
U="${GHCR_USER:-$(kv_get ghcr-user)}"
P="${GHCR_PAT:-$(kv_get ghcr-pat)}"
if [[ -n "${GHCR_USER:-}" && -n "${GHCR_PAT:-}" ]]; then
  az keyvault secret set --vault-name "$VAULT" -n ghcr-user --value "$GHCR_USER" -o none 2>/dev/null
  az keyvault secret set --vault-name "$VAULT" -n ghcr-pat  --value "$GHCR_PAT"  -o none 2>/dev/null
  echo "  stored the GHCR credentials in Key Vault (ghcr-user / ghcr-pat)"
fi
if [[ -z "$U" || -z "$P" ]]; then
  echo "No GHCR credentials found. Run once as:"
  echo "  GHCR_USER=<github-username> GHCR_PAT=<pat-with-read:packages> TAG=$TAG $0"
  exit 1
fi

echo "ACR : $ACR"
echo "TAG : $TAG"
echo

echo "=== what is in ACR right now ==="
MISSING=""
for s in $SERVICES; do
  have=$(az acr repository show-tags -n "$ACR" --repository "$DST_REPO/$s" -o tsv 2>/dev/null | grep -Fx "$TAG")
  if [[ -n "$have" ]]; then printf "  %-16s %s\n" "$s" "present"
  else printf "  %-16s %s\n" "$s" "MISSING"; MISSING="$MISSING $s"; fi
done

[[ "$MODE" == "--check" ]] && { echo; echo "(--check only, nothing changed)"; exit 0; }
[[ -z "$MISSING" ]] && { echo; echo "Everything is already present — nothing to do."; exit 0; }

echo
echo "=== import ==="
FAILED=""
for s in $MISSING; do
  printf "  %-16s " "$s"
  if az acr import -n "$ACR" \
       --source "$SRC_REPO/$s:$TAG" \
       -t "$DST_REPO/$s:$TAG" \
       --username "$U" --password "$P" >/dev/null 2>&1; then
    echo "OK"
  else
    echo "FAIL"; FAILED="$FAILED $s"
  fi
done

echo
echo "=== verify (by digest) ==="
BAD=""
for s in $SERVICES; do
  d=$(az acr manifest show-metadata "$ACR.azurecr.io/$DST_REPO/$s:$TAG" --query digest -o tsv 2>/dev/null)
  if [[ -n "$d" ]]; then printf "  %-16s %s\n" "$s" "${d:0:24}"
  else printf "  %-16s %s\n" "$s" "MISSING"; BAD="$BAD $s"; fi
done

echo
if [[ -n "$BAD" ]]; then
  echo "!! these are still missing:$BAD"
  echo "   Does the PAT carry 'read:packages'? And was that image actually built on GHCR with that tag?"
  exit 1
fi
echo "All 13 images are in ACR at tag $TAG."
echo "Next: change global.image.tag in the values file."
