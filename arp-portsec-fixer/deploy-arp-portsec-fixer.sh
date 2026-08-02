#!/bin/bash
# deploy-arp-portsec-fixer.sh — Deploy ARP Port-Security Fixer Controller
#
# Creates ConfigMap from script and applies the Deployment + RBAC.
# Run from the directory containing arp-portsec-fixer.sh and .yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="kube-system"

echo "=== ARP Port-Security Fixer Controller Deploy ==="

# Check required files
for f in arp-portsec-fixer.sh arp-portsec-fixer.yaml; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        echo "ERROR: $f not found in $SCRIPT_DIR"
        exit 1
    fi
done

# Delete existing ConfigMap if present (idempotent)
echo "[1/3] Cleaning up existing ConfigMap..."
kubectl delete configmap arp-portsec-scripts -n "$NAMESPACE" --ignore-not-found

# Create ConfigMap from script
echo "[2/3] Creating ConfigMap from arp-portsec-fixer.sh..."
kubectl create configmap arp-portsec-scripts \
    --from-file=arp-portsec-fixer.sh="$SCRIPT_DIR/arp-portsec-fixer.sh" \
    -n "$NAMESPACE"

# Apply Deployment + RBAC
echo "[3/3] Applying Deployment + RBAC..."
kubectl apply -f "$SCRIPT_DIR/arp-portsec-fixer.yaml"

echo ""
echo "=== Deploy complete ==="
echo ""
echo "Verify:"
echo "  kubectl get deployment arp-portsec-fixer -n $NAMESPACE"
echo "  kubectl get pods -n $NAMESPACE -l app=arp-portsec-fixer"
echo "  kubectl logs -n $NAMESPACE -l app=arp-portsec-fixer --tail=20"
echo ""
echo "Label pods to enable ARP spoofing:"
echo "  kubectl label pod <attacker-pod> arp.kumi.io/attacker=true"
echo ""
echo "Set LOG_LEVEL=DEBUG for verbose output:"
echo "  kubectl set env deployment/arp-portsec-fixer -n $NAMESPACE LOG_LEVEL=DEBUG"
