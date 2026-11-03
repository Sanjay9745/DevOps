#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="autoscale-demo"
ACTION="${1:-help}"

echo "=================================================================="
echo "  Kubernetes Two-Layer Autoscaling Lab (HPA + Node Autoscaling)"
echo "=================================================================="

case "$ACTION" in
  deploy)
    echo "[1/4] Checking if metrics-server is installed..."
    if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
      echo "  -> Installing metrics-server (patched for local Kind/Minikube/Docker clusters)..."
      kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
      kubectl patch deployment metrics-server -n kube-system --type='json' \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
      echo "  -> Waiting for metrics-server to be ready..."
      kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
    else
      echo "  -> metrics-server is already running!"
    fi

    echo "[2/4] Creating namespace '$NAMESPACE'..."
    kubectl apply -f 00-namespace.yaml

    echo "[3/4] Deploying Flash-Sale Checkout API and Service..."
    kubectl apply -f 01-app-deployment.yaml
    kubectl rollout status deployment/checkout-api -n "$NAMESPACE" --timeout=120s

    echo "[4/4] Applying HorizontalPodAutoscaler (HPA) & PodDisruptionBudget (PDB)..."
    kubectl apply -f 02-hpa.yaml

    echo ""
    echo "SUCCESS! Application & HPA are deployed."
    echo "Next steps:"
    echo "  ./run-demo.sh spike    # Trigger a flash-sale traffic spike"
    echo "  ./run-demo.sh watch    # Live-monitor HPA, Pods, and Nodes"
    echo "  ./run-demo.sh cooldown # Stop traffic and watch scale-in to 1 pod"
    ;;

  spike)
    echo "Starting Flash-Sale Load Generator..."
    kubectl apply -f 04-load-generator.yaml
    echo "Traffic spike started! Run './run-demo.sh watch' to observe scaling in real time."
    ;;

  cooldown)
    echo "Stopping Flash-Sale Load Generator..."
    kubectl delete -f 04-load-generator.yaml --ignore-not-found
    echo "Traffic stopped! Watch HPA wait for stabilizationWindowSeconds (180s) and scale pods down."
    ;;

  watch)
    echo "Watching HPA, Pods, and Nodes (Press Ctrl+C to exit)..."
    watch -n 2 "echo '=== 1. HORIZONTAL POD AUTOSCALER ===' && kubectl get hpa -n $NAMESPACE && echo '' && echo '=== 2. PODS (Look for Running / Pending) ===' && kubectl get pods -n $NAMESPACE -o wide && echo '' && echo '=== 3. WORKER NODES ===' && kubectl get nodes -o wide"
    ;;

  cleanup)
    echo "Cleaning up '$NAMESPACE' namespace..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    ;;

  *)
    echo "Usage: ./run-demo.sh {deploy|spike|cooldown|watch|cleanup}"
    exit 1
    ;;
esac
