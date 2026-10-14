#!/usr/bin/env bash
# Key Vault seeding — run from the jumphost (inside the VNet; the vault's public access is off).
#
#   chmod +x kv-seed-secrets.sh
#   ./kv-seed-secrets.sh
#
# The caller needs "Key Vault Secrets Officer" (or Administrator) on the vault.
# Re-running is SAFE: a secret that already exists is NOT touched (creating a new
# version would change the signing keys and break every live session and token).
# To rotate one deliberately: FORCE=1 ONLY=portal-jwt-secret ./kv-seed-secrets.sh
set -euo pipefail

VAULT="${VAULT:-kv-tokenfactory}"
FORCE="${FORCE:-0}"
ONLY="${ONLY:-}"

# ── generators ───────────────────────────────────────────────────────────────
rand()   { openssl rand -base64 48 | tr -d '/+=\n' | head -c "${1:-48}"; }
b64_32() { openssl rand -base64 32; }          # encryption-key: base64 OF 32 bytes
# Keycloak password policy: upper + lower + digit + special
kcpass() { printf '%s%s%s%s' "$(rand 20)" 'A' 'a7' '!'; }

have() { az keyvault secret show --vault-name "$VAULT" -n "$1" >/dev/null 2>&1; }

put() {
  local name="$1" val="$2"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0
  if have "$name" && [[ "$FORCE" != "1" ]]; then
    printf '  %-30s SKIP (already exists)\n' "$name"; return 0
  fi
  if [[ -z "$val" ]]; then
    printf '  %-30s !! EMPTY — set it by hand, see below\n' "$name"; return 0
  fi
  az keyvault secret set --vault-name "$VAULT" -n "$name" --value "$val" -o none
  printf '  %-30s SET\n' "$name"
}

echo "Vault: $VAULT"
echo
echo "-- generated automatically --"
put admin-api-key                "$(rand 48)"
put auth-state-signing-key       "$(rand 48)"
put ce-userinfo-signing-key      "$(rand 48)"   # must stay STABLE across upgrades
put portal-jwt-secret            "$(rand 48)"
put encryption-key               "$(b64_32)"    # AES-256-GCM — base64 of exactly 32 bytes
put kc-admin-username            "admin"
put kc-admin-password            "$(kcpass)"
put platform-admin-password      "$(kcpass)"
put platform-init-admin-password "$(kcpass)"
put redis-password               "$(rand 32)"
put s3-access-key                "$(rand 20)"
put s3-secret-key                "$(rand 40)"
put db-password                  "$(rand 32)"   # password for the PG role `tokenfactory`
put kc-db-password               "$(rand 32)"   # password for the PG role `keycloak`

echo
echo "-- supplied externally (pass an env var, otherwise left empty) --"
put google-client-secret    "${GOOGLE_CLIENT_SECRET:-}"
put microsoft-client-secret "${MICROSOFT_CLIENT_SECRET:-}"
put stripe-secret-key       "${STRIPE_SECRET_KEY:-}"
put stripe-webhook-secret   "${STRIPE_WEBHOOK_SECRET:-}"
put smtp-password           "${RESEND_API_KEY:-}"   # Resend SMTP: user=resend, pass=API key

cat <<'EOF'

Fill in whatever was left empty like this:
  az keyvault secret set --vault-name kv-tokenfactory -n google-client-secret --value '...'

Two things must follow, or the application will not start:
  1. Create the PG roles — each password must match the Key Vault value EXACTLY:
       CREATE ROLE tokenfactory LOGIN PASSWORD '<db-password>';
       CREATE ROLE keycloak     LOGIN PASSWORD '<kc-db-password>';
       CREATE ROLE openfga      LOGIN PASSWORD '<db-password>';
  2. Apply the SecretProviderClass + syncer, then wait for the Secret to appear:
       kubectl apply -f secretproviderclass-tokenfactory.yaml
       kubectl -n xailon-tf-prod rollout status deploy/akv-secret-syncer
       kubectl -n xailon-tf-prod get secret tokenfactory-secrets \
         -o jsonpath='{.data}' | tr ',' '\n' | wc -l     # should print 19
EOF
