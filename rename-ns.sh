#!/usr/bin/env bash
# xalion-tf-prod  →  xailon-tf-prod  (spelling fix)
#
# A namespace cannot be RENAMED — you create a new one and redeploy into it.
# That is cheap here because the namespace holds NO DATA:
#   - all real data is in Azure PG (external), including the migration versions
#   - minio's tf-ledger-archive bucket: 0 files
#   - redis: an 871-byte dump.rdb (cache)
#   - secrets come from Key Vault, the syncer will fetch them again
#
# The phases are separate — run one, check it, then the next:
#   ./rename-ns.sh plan      read-only, changes nothing
#   ./rename-ns.sh pre       new ns + SPC + syncer + Secret + TLS   (NO DOWNTIME)
#   ./rename-ns.sh cut       uninstall the old + install the new     (DOWNTIME)
#   ./rename-ns.sh openmeter point openmeter's NetworkPolicy at the new ns
#   ./rename-ns.sh verify    checks
#   ./rename-ns.sh cleanup   delete the old ns (asks first)
set -euo pipefail

OLD_NS=${OLD_NS:-xalion-tf-prod}
NEW_NS=${NEW_NS:-xailon-tf-prod}
REPO=${REPO:-$HOME/xalion_7oct/ai-gateway-platform}
CHART=$REPO/helm/tokenfactory
VALUES=${VALUES:-values-xailon-prod.yaml}
RELEASE=tokenfactory
XDIR=$HOME/xalion
CERT=${CERT:-$HOME/wild.xailon-cert.crt}
KEY=${KEY:-$HOME/wild.xailon-key.key}
SPC_SRC=$XDIR/secretproviderclass-tokenfactory.yaml
SPC_NEW=$XDIR/.spc-$NEW_NS.yaml

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ask()  { read -r -p "$1 [yes/no] " a; [ "$a" = yes ]; }
need() { [ -f "$1" ] || { echo "not found: $1"; exit 1; }; }

case "${1:-}" in

plan)
  say "CURRENT state"
  kubectl get ns "$OLD_NS" "$NEW_NS" 2>&1 | sed 's/^/  /' || true
  helm list -n "$OLD_NS" 2>/dev/null | sed 's/^/  /'
  echo "  pods: $(kubectl get po -n "$OLD_NS" --no-headers 2>/dev/null | wc -l)"
  say "PVCs (these will be left behind — both are empty)"
  kubectl get pvc -n "$OLD_NS" --no-headers 2>/dev/null | awk '{print "  "$1"  "$4}'
  say "Files that carry the namespace name"
  grep -l "$OLD_NS" "$XDIR"/*.yaml "$XDIR"/*.sh 2>/dev/null | sed 's|.*/|  |'
  say "Things created outside the chart (these must be recreated)"
  echo "  SecretProviderClass tokenfactory-kv"
  echo "  Deployment akv-secret-syncer"
  echo "  Secret xailon-ingress-tls"
  say "Cloudflare — must be changed BY HAND"
  echo "  Only ONE needs changing (confirm against the tunnel table in the manager):"
  echo "    api.xailon.ai : envoy.$OLD_NS.svc.cluster.local:8080"
  echo "                 -> envoy.$NEW_NS.svc.cluster.local:8080"
  echo "  Do NOT touch (these are namespace-independent):"
  echo "    console/admin/auth.xailon.ai -> nginx-ingress-controller.nginx-ingress.svc:80"
  echo "    argo.xailon.ai               -> argocd ns"
  echo "  SEPARATE ISSUE (nothing to do with the rename):"
  echo "    the xailon.ai apex is NOT reaching the cluster — from outside you get a"
  echo "    parked page (85KB, title \"xailon.ai\", no _next), whereas tf-site-web"
  echo "    serves a 186KB Next.js page. Have the apex tunnel hostname/DNS checked."
  ;;

pre)
  need "$SPC_SRC"; need "$CERT"; need "$KEY"
  say "1/3  copy of the SPC manifest under the new namespace name"
  # deploy-secrets.sh --partial copies the syncer Deployment AS IS (its
  # `namespace:` is hardcoded), so passing NS= is NOT enough — the manifest has
  # to be sed-ed.
  sed "s/\b$OLD_NS\b/$NEW_NS/g" "$SPC_SRC" > "$SPC_NEW"
  echo "  $SPC_NEW  (name replaced in $(grep -c "$NEW_NS" "$SPC_NEW") places)"
  grep -n "namespace: $NEW_NS" "$SPC_NEW" | sed 's/^/    /'

  say "2/3  secrets — new ns, SPC, syncer, Secret"
  # the variable is called NS, not NAMESPACE
  ( cd "$XDIR" && NS="$NEW_NS" MANIFEST="$SPC_NEW" ./deploy-secrets.sh --partial )

  say "3/3  TLS secret"
  kubectl create secret tls xailon-ingress-tls \
    --cert="$CERT" --key="$KEY" -n "$NEW_NS" \
    --dry-run=client -o yaml | kubectl apply -f -

  say "Result (the old namespace was not touched — no downtime)"
  kubectl get secret -n "$NEW_NS" tokenfactory-secrets xailon-ingress-tls \
    -o custom-columns=NAME:.metadata.name,TYPE:.type,KEYS:'.data' --no-headers 2>/dev/null \
    | awk '{print "  "$1"  "$2}'
  echo "  tokenfactory-secrets keys: $(kubectl get secret tokenfactory-secrets -n "$NEW_NS" -o go-template='{{len .data}}' 2>/dev/null)"
  echo
  echo "If this looks right:  ./rename-ns.sh cut"
  ;;

cut)
  k=$(kubectl get secret tokenfactory-secrets -n "$NEW_NS" -o go-template='{{len .data}}' 2>/dev/null || echo 0)
  [ "$k" -ge 19 ] || { echo "stop: tokenfactory-secrets in $NEW_NS has $k keys (19 required). Run 'pre' first."; exit 1; }
  echo "DOWNTIME starts here. The two namespaces will NOT run side by side —"
  echo "there is one Azure PG, and the tf-accounts-purge / tf-ledger sweeps would run twice."
  ask "Uninstall the old release and install the new one?" || exit 0

  say "1/2  remove the old release"
  helm uninstall "$RELEASE" -n "$OLD_NS" --wait --timeout 10m

  say "2/2  install into the new namespace"
  ( cd "$CHART" && helm install "$RELEASE" . -n "$NEW_NS" --create-namespace \
      -f "$VALUES" --timeout 20m )
  echo
  echo "Next:  ./rename-ns.sh openmeter   then   ./rename-ns.sh verify"
  ;;

openmeter)
  say "point openmeter's NetworkPolicy at the new application namespace"
  echo "  the NP only admits tf-auth/tf-ledger from the application namespace —"
  echo "  without this, usage metering from the new namespace stays blocked."
  echo "  (--set overrides the values file, so the file does not need sed-ing)"
  ask "Re-run the openmeter deploy (its pods will roll)?" || exit 0
  ( cd "$XDIR" && APP_NAMESPACE="$NEW_NS" ./deploy-openmeter-azure.sh )
  ;;

verify)
  say "release"
  helm list -n "$NEW_NS" 2>/dev/null | sed 's/^/  /'
  say "pods that are not Running/Completed"
  kubectl get po -n "$NEW_NS" --no-headers 2>/dev/null \
    | awk '$3!="Running" && $3!="Completed" {print "  "$1"  "$3"  "$5}'
  kubectl get po -n "$NEW_NS" --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | sed 's/^/  /'
  say "Ingress / Keycloak / envoy"
  kubectl get ing -n "$NEW_NS" --no-headers 2>/dev/null | sed 's/^/  /'
  kubectl get sts keycloak -n "$NEW_NS" -o custom-columns=READY:.status.readyReplicas,WANT:.spec.replicas --no-headers 2>/dev/null | sed 's/^/  keycloak /'
  kubectl get deploy envoy -n "$NEW_NS" -o custom-columns=READY:.status.readyReplicas,WANT:.spec.replicas --no-headers 2>/dev/null | sed 's/^/  envoy    /'
  say "Keycloak Infinispan cluster (3 members expected)"
  kubectl logs keycloak-0 -n "$NEW_NS" --tail=400 2>/dev/null | grep -o 'ISPN000094.*' | tail -1 | sed 's/^/  /'
  say "migrations — dirty should be set nowhere"
  kubectl logs -n "$NEW_NS" -l app.kubernetes.io/name=tf-auth -c db-migrate --tail=3 2>/dev/null | sed 's/^/  /'
  say "from outside (through Cloudflare)"
  for u in https://xailon.ai https://console.xailon.ai https://admin.xailon.ai https://auth.xailon.ai; do
    printf '  %-28s %s\n' "$u" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$u" || echo ERR)"
  done
  echo "  api.xailon.ai : was the Cloudflare target changed? (envoy.$NEW_NS.svc) — until then this fails"
  printf '  %-28s %s\n' "https://api.xailon.ai/v1/models" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 https://api.xailon.ai/v1/models || echo ERR)"
  ;;

cleanup)
  say "old namespace: $OLD_NS"
  kubectl get all -n "$OLD_NS" --no-headers 2>/dev/null | wc -l | sed 's/^/  objects remaining: /'
  echo "  (the minio-data/redis-data PVCs go too — both are empty)"
  ask "DELETE $OLD_NS — this cannot be undone. Proceed?" || exit 0
  kubectl delete ns "$OLD_NS"
  ;;

*) sed -n '2,20p' "$0"; exit 1 ;;
esac
