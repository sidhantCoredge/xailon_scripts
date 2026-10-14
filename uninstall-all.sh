#!/usr/bin/env bash
# Uninstall both xalion and openmeter. IN THE CORRECT ORDER.
set -uo pipefail
say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "0/4  state beforehand (for the record)"
helm list -A --no-headers 2>/dev/null | awk '{print "  "$1"  ns="$2"  rev="$3"  "$8}'
kubectl get chi -A --no-headers 2>/dev/null | sed 's/^/  CHI: /'

say "1/4  remove the CHI first (while the operator is still alive — this is the point)"
if kubectl get chi openmeter -n openmeter >/dev/null 2>&1; then
  kubectl delete chi openmeter -n openmeter --timeout=180s || {
    echo "  CHI delete is stuck — removing the finalizer to free it"
    kubectl patch chi openmeter -n openmeter --type=merge -p '{"metadata":{"finalizers":[]}}' || true
  }
  echo "  CHI removed"
else
  echo "  no CHI present"
fi

say "2/4  openmeter uninstall"
helm uninstall openmeter -n openmeter --timeout=10m 2>&1 | tail -3

say "3/4  uninstall xalion (tokenfactory)"
helm uninstall tokenfactory -n xailon-tf-prod --timeout=15m 2>&1 | tail -3

say "4/4  what is left"
echo "  -- helm releases --"
helm list -A --no-headers 2>/dev/null | awk '{print "    "$1"  ns="$2}' || echo "    none"
echo "  -- pods left in xailon-tf-prod --"
kubectl get po -n xailon-tf-prod --no-headers 2>/dev/null | awk '{print "    "$1"  "$3}' || echo "    none"
echo "  -- pods left in the openmeter namespace --"
kubectl get po -n openmeter --no-headers 2>/dev/null | awk '{print "    "$1"  "$3}' || echo "    none"
echo "  -- PVCs (whatever remains) --"
kubectl get pvc -A --no-headers 2>/dev/null | grep -E 'xailon-tf-prod|openmeter' | awk '{print "    "$1"/"$2}' || echo "    none"
echo "  -- NetworkPolicies --"
kubectl get netpol -A --no-headers 2>/dev/null | grep -E 'xailon-tf-prod|openmeter' | awk '{print "    "$1"/"$2}' || echo "    none"

cat <<'NOTE'

── things outside helm are LEFT BEHIND (deliberately) ──
  xailon-tf-prod : akv-secret-syncer, SecretProviderClass tokenfactory-kv,
                   Secret tokenfactory-secrets, Secret xailon-ingress-tls
  Azure PG       : tokenfactory / keycloak / openmeter / svix — all data safe
  Key Vault      : all secrets
  ACR            : all images

── to bring it back ──
  xalion    : cd ~/xalion_7oct/ai-gateway-platform/helm/tokenfactory
              helm install tokenfactory . -n xailon-tf-prod -f values-xailon-prod.yaml --timeout 20m
  openmeter : cd ~/xalion && APP_NAMESPACE=xailon-tf-prod ./deploy-openmeter-azure.sh
NOTE
