#!/bin/bash
# deploy-span-mirror.sh — Deploy SPAN Mirror Controller
#
# Creates ConfigMap from scripts and applies the DaemonSet.
# Run from the directory containing span-mirror-controller.sh and .yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="kube-system"

echo "=== SPAN Mirror Controller Deploy ==="

# Check required files
for f in span-mirror-controller.sh span-mirror-controller.yaml; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        echo "ERROR: $f not found in $SCRIPT_DIR"
        exit 1
    fi
done

# Delete existing ConfigMap if present (idempotent)
echo "[1/3] Cleaning up existing ConfigMap..."
kubectl delete configmap span-mirror-scripts -n "$NAMESPACE" --ignore-not-found

# Create ConfigMap from script
echo "[2/3] Creating ConfigMap from span-mirror-controller.sh..."
kubectl create configmap span-mirror-scripts \
    --from-file=span-mirror-controller.sh="$SCRIPT_DIR/span-mirror-controller.sh" \
    -n "$NAMESPACE"

# Apply DaemonSet + RBAC
echo "[3/3] Applying DaemonSet + RBAC..."
kubectl apply -f "$SCRIPT_DIR/span-mirror-controller.yaml"

echo ""
echo "=== Deploy complete ==="
echo ""
echo "Verify:"
echo "  kubectl get daemonset span-mirror-controller -n $NAMESPACE"
echo "  kubectl get pods -n $NAMESPACE -l app=span-mirror-controller -o wide"
echo "  kubectl logs -n $NAMESPACE -l app=span-mirror-controller --tail=20"
echo ""
echo "Label pods to enable mirroring:"
echo "  kubectl label pod <target-pod> mirror.kumi.io/target=true"
echo "  kubectl label pod <sniffer-pod> mirror.kumi.io/sniffer=true"
echo ""
echo "Set LOG_LEVEL=DEBUG for verbose output:"
echo "  kubectl set env daemonset/span-mirror-controller -n $NAMESPACE LOG_LEVEL=DEBUG"
