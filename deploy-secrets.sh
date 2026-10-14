#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# xalion — build tokenfactory-secrets from Key Vault
#
#   ./deploy-secrets.sh            # prompts for missing secrets, then applies
#   ./deploy-secrets.sh --dummy    # puts PLACEHOLDER in the 5 external secrets
#   ./deploy-secrets.sh --check    # reports status only, changes nothing
#   ./deploy-secrets.sh --partial  # build the SPC from ONLY the keys present in KV
#
# --dummy is for a bring-up test only. With it, Google/Microsoft login, Stripe
# billing and email OTP will all three be BROKEN.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
NS="${NS:-xailon-tf-prod}"
MANIFEST="${MANIFEST:-$(dirname "$0")/secretproviderclass-tokenfactory.yaml}"
MODE="${1:-}"

# The 19 objects the SecretProviderClass asks for — list taken from the render.
# The mount is ALL-OR-NOTHING: one missing secret fails the entire mount.
REQUIRED=(
  admin-api-key auth-state-signing-key ce-userinfo-signing-key db-password
  encryption-key google-client-secret kc-admin-password kc-admin-username
  kc-db-password microsoft-client-secret platform-admin-password
  platform-init-admin-password portal-jwt-secret redis-password
  s3-access-key s3-secret-key smtp-password stripe-secret-key
  stripe-webhook-secret
  # Not a chart key — cloudflared reads this one as TUNNEL_TOKEN. It is kept in
  # the same Secret so that a separate SPC + syncer is not needed; the chart is
  # indifferent to extra keys.
  cloudflare-tunnel-token
)
# These five come from outside — they cannot be generated.
EXTERNAL=(google-client-secret microsoft-client-secret smtp-password
          stripe-secret-key stripe-webhook-secret)

az_q() { az "$@" 2>/dev/null; }
have() { az_q keyvault secret show --vault-name "$VAULT" -n "$1" >/dev/null; }

echo "Vault : $VAULT"
echo "NS    : $NS"
echo

# ── 1. status ───────────────────────────────────────────────────────────────
missing=()
for s in "${REQUIRED[@]}"; do have "$s" || missing+=("$s"); done
echo "Key Vault: $(( ${#REQUIRED[@]} - ${#missing[@]} ))/${#REQUIRED[@]} present"
if ((${#missing[@]})); then
  printf '  missing: %s\n' "${missing[@]}"
fi

[[ "$MODE" == "--check" ]] && { echo; echo "(--check only, nothing changed)"; exit 0; }

# ── --partial: trim the SPC down to the keys that exist ─────────────────────
# The syncer does not read these values itself — it only mounts them. So the 14
# that are in KV give a working mount TODAY; add the rest later.
# For the app pods, 10 keys are `optional: true` and 9 are required — see below.
if [[ "$MODE" == "--partial" ]]; then
  present=(); for s in "${REQUIRED[@]}"; do have "$s" && present+=("$s"); done
  ((${#present[@]})) || { echo "KV is empty — run ./kv-seed-secrets.sh first"; exit 1; }
  GEN="$(dirname "$0")/.spc-partial.yaml"
  {
    printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n---\n' "$NS"
    printf 'apiVersion: secrets-store.csi.x-k8s.io/v1\nkind: SecretProviderClass\n'
    printf 'metadata: { name: tokenfactory-kv, namespace: %s }\nspec:\n  provider: azure\n  parameters:\n' "$NS"
    printf '    usePodIdentity: "false"\n    useVMManagedIdentity: "true"\n'
    printf '    userAssignedIdentityID: "35f2629f-beb1-438e-8105-f3202518249d"\n'
    printf '    keyvaultName: "%s"\n    tenantId: "6fc131bd-72da-4e55-bb85-5e873ab21dc6"\n' "$VAULT"
    printf '    objects: |\n      array:\n'
    for k in "${present[@]}"; do printf '        - |\n          objectName: %s\n          objectType: secret\n' "$k"; done
    printf '  secretObjects:\n    - secretName: tokenfactory-secrets\n      type: Opaque\n      data:\n'
    for k in "${present[@]}"; do printf '        - { objectName: %s, key: %s }\n' "$k" "$k"; done
    printf -- '---\n'
    sed -n '/^apiVersion: apps\/v1/,$p' "$MANIFEST"
  } > "$GEN"
  echo
  echo "-- trimmed SPC written: ${#present[@]} keys --> $GEN"
  MANIFEST="$GEN"
  REQUIRED=("${present[@]}")
  missing=()
  if [[ "${2:-}" == "--dry" ]]; then
    echo "-- --dry: file written, not applied --"; echo; cat "$GEN"; exit 0
  fi
fi

# ── 2. fill in what is missing ──────────────────────────────────────────────
if ((${#missing[@]})); then
  echo
  for s in "${missing[@]}"; do
    is_ext=0; for e in "${EXTERNAL[@]}"; do [[ "$e" == "$s" ]] && is_ext=1; done
    if ((is_ext == 0)); then
      echo "!! $s should have been generated — run ./kv-seed-secrets.sh first"; exit 1
    fi
    if [[ "$MODE" == "--dummy" ]]; then
      val="PLACEHOLDER-$s"
      echo "  $s  <- PLACEHOLDER"
    else
      printf '  enter the value for %s (empty = skip): ' "$s"
      read -rs val; echo
      [[ -z "$val" ]] && { echo "  (skipped — the mount will keep failing)"; continue; }
    fi
    az keyvault secret set --vault-name "$VAULT" -n "$s" --value "$val" -o none
  done
  # count again
  missing=(); for s in "${REQUIRED[@]}"; do have "$s" || missing+=("$s"); done
  if ((${#missing[@]})); then
    echo
    echo "${#missing[@]} are still missing — the mount would fail, so not applying."
    printf '  %s\n' "${missing[@]}"
    exit 1
  fi
fi

echo
echo "All ${#REQUIRED[@]} are present in Key Vault."

# ── 3. apply ────────────────────────────────────────────────────────────────
echo
echo "-- apply --"
kubectl apply -f "$MANIFEST"

# Changing the SPC does NOT make the pod re-mount on its own — the Deployment
# stays "unchanged" and the CSI driver keeps running with the old object set. A
# new key only arrives on a FRESH volume mount, hence the forced restart here.
echo
echo "-- recreate the syncer pod (the SPC changed, so a fresh mount is required) --"
# `rollout restart` is DELIBERATELY not used: it changes the pod template and
# creates a NEW ReplicaSet, while the CSI driver leaves the Secret's
# ownerReference on the OLD RS. If that old RS is ever emptied and garbage
# collected, Kubernetes deletes the Secret too and every app pod goes down.
# Deleting the pod keeps the same RS, so ownership stays valid and the mount is
# still fresh.
kubectl -n "$NS" delete pod -l app.kubernetes.io/name=akv-secret-syncer --wait=false

echo
echo "-- waiting for the syncer (this is where the CSI mount happens) --"
if ! kubectl -n "$NS" rollout status deploy/akv-secret-syncer --timeout=180s; then
  echo
  echo "!! the syncer did not come up. The real reason is below:"
  kubectl -n "$NS" describe pod -l app.kubernetes.io/name=akv-secret-syncer \
    | sed -n '/Events:/,$p'
  echo
  echo "-- is ACR attached? (check this on ImagePullBackOff) --"
  acr=$(az_q aks show -g rg-tokenfactory -n aks-tokenfactory \
          --query "servicePrincipalProfile.clientId" -o tsv || true)
  az_q aks check-acr -g rg-tokenfactory -n aks-tokenfactory --acr acrtokenfactory \
    || echo "   (check-acr did not run — you will need 'az aks update -g rg-tokenfactory -n aks-tokenfactory --attach-acr acrtokenfactory')"
  exit 1
fi

# ── 4. verify ───────────────────────────────────────────────────────────────
echo
echo "-- tokenfactory-secrets --"
# The CSI driver updates the k8s Secret SHORTLY AFTER the pod becomes Ready.
# Reading once is a race (this has actually bitten: the old count showed even
# after a restart). So poll.
got=""
for _ in $(seq 1 20); do
  got=$(kubectl -n "$NS" get secret tokenfactory-secrets \
          -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | sort || true)
  [[ "$(echo "$got" | grep -c .)" == "${#REQUIRED[@]}" ]] && break
  sleep 3
done
if [[ -z "$got" ]]; then
  echo "!! the Secret was never created. Check the SPC and the syncer's mount attributes."
  exit 1
fi
n=$(echo "$got" | wc -l | tr -d ' ')
echo "$got" | sed 's/^/   /'
echo
if [[ "$n" == "${#REQUIRED[@]}" ]]; then
  echo "OK — $n/${#REQUIRED[@]} keys."
else
  echo "!! got $n keys, expected ${#REQUIRED[@]}."
  comm -23 <(printf '%s\n' "${REQUIRED[@]}" | sort) <(echo "$got") | sed 's/^/   missing: /'
  exit 1
fi
