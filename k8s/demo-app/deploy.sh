#!/usr/bin/env bash
set -Eeuo pipefail

# Every cluster command targets the existing Kind context explicitly.
readonly CONTEXT="kind-dev-cluster"
readonly RELEASE="demo-traefik"
readonly TRAEFIK_NAMESPACE="traefik-demo"
readonly CHART_VERSION="41.6.0"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly WAIT_TIMEOUT="300s"

for command in kubectl helm; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$command" >&2
    exit 1
  fi
done

# Check the app files before making any cluster changes.
for app in app1 app2; do
  for file in index.html styles.css nginx.conf; do
    if [[ ! -r "$SCRIPT_DIR/$app/$file" ]]; then
      printf 'Required app file is missing or unreadable: %s/%s/%s\n' "$SCRIPT_DIR" "$app" "$file" >&2
      exit 1
    fi
  done
done

kube() { kubectl --context "$CONTEXT" "$@"; }
diagnostics() {
  local exit_code=$?
  printf '\nDeployment failed (exit %s). Current resources:\n' "$exit_code" >&2
  kube -n demo get pods,services,ingresses -o wide || true
  kube -n demo get events --sort-by=.lastTimestamp || true
  kube -n "$TRAEFIK_NAMESPACE" get pods,services -o wide || true
  exit "$exit_code"
}
trap diagnostics ERR

if ! kubectl config get-contexts "$CONTEXT" -o name | grep -Fxq "$CONTEXT"; then
  printf 'Context %s is missing. Export the existing cluster kubeconfig first:\n' "$CONTEXT" >&2
  printf '  kind export kubeconfig --name dev-cluster\n' >&2
  exit 1
fi

printf 'Checking existing cluster %s...\n' "$CONTEXT"
kube cluster-info
kube wait --for=condition=Ready nodes --all --timeout="$WAIT_TIMEOUT"
kube get nodes -o wide

kube apply -f "$SCRIPT_DIR/00-namespace.yaml"

# Turn ordinary source files into ConfigMaps, without embedding code in YAML.
# The --from-file name before '=' becomes the ConfigMap data key.
for app in app1 app2; do
  kube -n demo create configmap "${app}-content" \
    --from-file=index.html="$SCRIPT_DIR/$app/index.html" \
    --from-file=styles.css="$SCRIPT_DIR/$app/styles.css" \
    --from-file=default.conf="$SCRIPT_DIR/$app/nginx.conf" \
    --dry-run=client -o yaml | kube apply -f -
done

helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update traefik
helm upgrade --install "$RELEASE" traefik/traefik \
  --kube-context "$CONTEXT" \
  --namespace "$TRAEFIK_NAMESPACE" --create-namespace \
  --version "$CHART_VERSION" \
  --values "$SCRIPT_DIR/traefik-values.yaml" \
  --skip-crds --wait --timeout "$WAIT_TIMEOUT"

kube apply \
  -f "$SCRIPT_DIR/01-app1.yaml" \
  -f "$SCRIPT_DIR/02-app2.yaml" \
  -f "$SCRIPT_DIR/03-ingress.yaml"

# NGINX reads its config at startup; restart on reruns to pick up ConfigMap edits.
kube -n demo rollout restart deployment/app1 deployment/app2
for deployment in app1 app2; do
  kube -n demo rollout status "deployment/$deployment" --timeout="$WAIT_TIMEOUT"
done
kube -n "$TRAEFIK_NAMESPACE" rollout status "deployment/$RELEASE" --timeout="$WAIT_TIMEOUT"

printf '\nDemo resources:\n'
kube -n demo get configmaps,deployments,pods,services,endpointslices,ingresses -o wide
kube get ingressclass demo-traefik
kube -n "$TRAEFIK_NAMESPACE" get deployments,pods,services -o wide
printf '\nOrders Console:     http://localhost:8080/app1/\n'
printf 'Inventory Dashboard: http://localhost:8080/app2/\n'

if [[ "${SKIP_PORT_FORWARD:-0}" == "1" ]]; then
  printf '\nStart the local entry point in a separate terminal:\n'
  printf 'kubectl --context %s -n %s port-forward --address 127.0.0.1 service/%s 8080:80\n' \
    "$CONTEXT" "$TRAEFIK_NAMESPACE" "$RELEASE"
else
  printf '\nStarting localhost:8080. Leave this terminal open; Ctrl+C stops forwarding.\n'
  exec kubectl --context "$CONTEXT" -n "$TRAEFIK_NAMESPACE" \
    port-forward --address 127.0.0.1 "service/$RELEASE" 8080:80
fi
