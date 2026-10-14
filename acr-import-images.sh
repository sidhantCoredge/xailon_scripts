#!/usr/bin/env bash
# =============================================================================
# TokenFactory images -> ACR (acrtokenfactory)
#
# Replaces the two older scripts:
#   ~/import-images.sh                 (had the 9 infra images, no KV creds,
#                                       always --force, username/password bug)
#   ~/xalion/acr-import-tf-images.sh   (had KV creds + idempotency, but only
#                                       handled the 13 tf-* services)
#
# USAGE
#   TAG=0.16.2-0f05311 ./acr-import-images.sh --check   # report only, no changes
#   TAG=0.16.2-0f05311 ./acr-import-images.sh           # import missing tf-* only
#                      ./acr-import-images.sh --infra   # import missing infra only
#   TAG=0.16.2-0f05311 ./acr-import-images.sh --all     # both
#
# WHY `az acr import` AND NOT docker pull/tag/push
#   - It runs SERVER-SIDE: ACR pulls from the source registry itself.
#   - No docker needed, and nothing is written to the jumphost disk.
#   - It does NOT traverse the Azure Firewall, so sources that are blocked from
#     inside the VNet (quay.io, for example) still import fine.
#   - Digests are preserved, which matters because keycloak is digest-pinned.
#
# REPOSITORY PATHS ARE DELIBERATE
#   The chart builds its image reference as registry + "/" + repository, so the
#   path inside ACR must match what the chart renders or the ref will not
#   resolve. Do not "tidy" these paths.
#
# CREDENTIALS
#   GHCR packages are private (anonymous pull returns 403), so a GitHub username
#   plus a PAT with `read:packages` is required for the tf-* images. Pass them
#   once via the environment and this script stores them in Key Vault as
#   `ghcr-user` / `ghcr-pat`; afterwards it reads them from there.
#
#     GHCR_USER=<github-username> GHCR_PAT=<pat> TAG=<tag> ./acr-import-images.sh
#
#   The infra images below are public and need no credentials, which is why
#   --infra works on its own.
# =============================================================================
set -uo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
ACR="${ACR:-acrtokenfactory}"
SRC_REPO="${SRC_REPO:-ghcr.io/infinia-technology/ai-gateway-platform}"
DST_REPO="${DST_REPO:-infinia-technology/ai-gateway-platform}"
MODE="${1:-}"

TF_SERVICES="tf-accounts tf-admin-web tf-auth tf-babel tf-control tf-docs-web
             tf-ledger tf-ops tf-portal-web tf-relay tf-shim tf-site-web tf-warden"

# "source|target" — the target is the exact path the chart renders.
# keycloak is pinned by DIGEST on purpose; az acr import preserves it.
INFRA_IMAGES=(
  "quay.io/keycloak/keycloak@sha256:82a77884f3af238beab1e7afd63b5f530e1b5c0590bd7aa60b40a40463e29b2c|quay.io/keycloak/keycloak:26.7.4"
  "docker.io/minio/minio:RELEASE.2025-09-07T16-13-09Z|minio/minio:RELEASE.2025-09-07T16-13-09Z"
  "docker.io/openfga/openfga:v1.8.9|openfga/openfga:v1.8.9"
  "docker.io/library/redis:7-alpine|redis:7-alpine"
  "docker.io/library/postgres:16-alpine|postgres:16-alpine"
  "docker.io/coredgeio/postgres:15|coredgeio/postgres:15"
  "docker.io/library/alpine:3.19|alpine:3.19"
  "docker.io/library/busybox:1.36|busybox:1.36"
  "docker.io/curlimages/curl:8.11.1|curlimages/curl:8.11.1"
)

case "$MODE" in
  --check) DO_TF=1; DO_INFRA=1; APPLY=0 ;;
  --infra) DO_TF=0; DO_INFRA=1; APPLY=1 ;;
  --all)   DO_TF=1; DO_INFRA=1; APPLY=1 ;;
  "")      DO_TF=1; DO_INFRA=0; APPLY=1 ;;
  *) echo "Unknown option: $MODE"; echo "Use --check | --infra | --all | (no flag)"; exit 2 ;;
esac

[[ $DO_TF -eq 1 ]] && : "${TAG:?TAG is required for tf-* images, e.g. TAG=0.16.2-0f05311}"

kv_get() { command az keyvault secret show --vault-name "$VAULT" -n "$1" --query value -o tsv 2>/dev/null; }
have_tag() { command az acr repository show-tags -n "$ACR" --repository "$1" -o tsv 2>/dev/null | grep -Fxq "$2"; }

U=""; P=""
if [[ $DO_TF -eq 1 ]]; then
  U="${GHCR_USER:-$(kv_get ghcr-user)}"
  P="${GHCR_PAT:-$(kv_get ghcr-pat)}"
  if [[ -n "${GHCR_USER:-}" && -n "${GHCR_PAT:-}" ]]; then
    command az keyvault secret set --vault-name "$VAULT" -n ghcr-user --value "$GHCR_USER" -o none 2>/dev/null
    command az keyvault secret set --vault-name "$VAULT" -n ghcr-pat  --value "$GHCR_PAT"  -o none 2>/dev/null
    echo "  stored GHCR credentials in Key Vault (ghcr-user / ghcr-pat)"
  fi
  if [[ -z "$U" || -z "$P" ]]; then
    echo "No GHCR credentials found. Run once as:"
    echo "  GHCR_USER=<github-username> GHCR_PAT=<pat-with-read:packages> TAG=${TAG:-<tag>} $0 $MODE"
    exit 1
  fi
fi

echo "ACR : $ACR"
[[ $DO_TF -eq 1 ]] && echo "TAG : $TAG"
echo

MISSING_TF=""; MISSING_INFRA=()

if [[ $DO_TF -eq 1 ]]; then
  echo "=== tf-* services (13) ==="
  for s in $TF_SERVICES; do
    if have_tag "$DST_REPO/$s" "$TAG"; then printf "  %-16s present\n" "$s"
    else printf "  %-16s MISSING\n" "$s"; MISSING_TF="$MISSING_TF $s"; fi
  done
  echo
fi

if [[ $DO_INFRA -eq 1 ]]; then
  echo "=== infra / helper images (9, public) ==="
  for pair in "${INFRA_IMAGES[@]}"; do
    t="${pair##*|}"; repo="${t%:*}"; tg="${t##*:}"
    if have_tag "$repo" "$tg"; then printf "  %-52s present\n" "$t"
    else printf "  %-52s MISSING\n" "$t"; MISSING_INFRA+=("$pair"); fi
  done
  echo
fi

if [[ $APPLY -eq 0 ]]; then
  echo "(--check only, nothing was changed)"
  exit 0
fi

if [[ -z "$MISSING_TF" && ${#MISSING_INFRA[@]} -eq 0 ]]; then
  echo "Everything already present — nothing to do."
  exit 0
fi

echo "=== importing ==="
FAILED=""

for s in $MISSING_TF; do
  printf "  %-52s " "$DST_REPO/$s:$TAG"
  if command az acr import -n "$ACR" \
       --source "$SRC_REPO/$s:$TAG" \
       --image  "$DST_REPO/$s:$TAG" \
       --username "$U" --password "$P" >/dev/null 2>&1; then
    echo "OK"
  else
    echo "FAIL"; FAILED="$FAILED $DST_REPO/$s:$TAG"
  fi
done

for pair in ${MISSING_INFRA+"${MISSING_INFRA[@]}"}; do
  src="${pair%%|*}"; dst="${pair##*|}"
  printf "  %-52s " "$dst"
  if command az acr import -n "$ACR" --source "$src" --image "$dst" >/dev/null 2>&1; then
    echo "OK"
  else
    echo "FAIL"; FAILED="$FAILED $dst"
  fi
done

echo
echo "=== verify (by digest) ==="
BAD=""

if [[ $DO_TF -eq 1 ]]; then
  for s in $TF_SERVICES; do
    d=$(command az acr manifest show-metadata "$ACR.azurecr.io/$DST_REPO/$s:$TAG" --query digest -o tsv 2>/dev/null)
    if [[ -n "$d" ]]; then printf "  %-52s %s\n" "$s:$TAG" "${d:0:24}"
    else printf "  %-52s %s\n" "$s:$TAG" "MISSING"; BAD="$BAD $s"; fi
  done
fi

if [[ $DO_INFRA -eq 1 ]]; then
  for pair in "${INFRA_IMAGES[@]}"; do
    t="${pair##*|}"
    d=$(command az acr manifest show-metadata "$ACR.azurecr.io/$t" --query digest -o tsv 2>/dev/null)
    if [[ -n "$d" ]]; then printf "  %-52s %s\n" "$t" "${d:0:24}"
    else printf "  %-52s %s\n" "$t" "MISSING"; BAD="$BAD $t"; fi
  done
fi

echo
if [[ -n "$BAD" ]]; then
  echo "!! still missing:$BAD"
  echo "   Check: does the PAT carry 'read:packages'? Was that tag actually built"
  echo "   and pushed to GHCR? Docker Hub rate limits can also cause this."
  exit 1
fi

echo "All requested images are in ACR."
[[ $DO_TF -eq 1 ]] && echo "Next: set global.image.tag to \"$TAG\" in values-xailon-prod.yaml, then helm upgrade."
exit 0
