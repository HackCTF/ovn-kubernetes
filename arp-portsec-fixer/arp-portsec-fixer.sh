#!/bin/bash
# arp-portsec-fixer.sh — ARP Port Security Fixer Controller (self-contained)
#
# Watches pods with label:
#   arp.kumi.io/attacker=true   → pods whose OVN LSPs must have port_security=[]
#                                  (allows ARP-spoofing MITM on layer2 labs)
#
# OVN-K re-applies port_security on every pod ensure (pod create/recreate), so
# this controller polls and re-clears it, keeping the fix persistent.
#
# Why port_security must be empty:
#   OVN port_security on the attacker LSP drops ARP replies whose payload
#   claims an IP not owned by the port (e.g. 0a:58:0a:0a:0a:09 10.10.10.9
#   cannot answer for 10.10.10.12/13). Clearing it lets arpspoof poison both
#   victim neighbour tables, cross-node included.
#
# Architecture note:
#   Shell polling (Enfoque A). Targets OVN NB (cluster-wide, single ovnkube-db)
#   via kubectl exec into the nb-ovsdb container, so it runs as a Deployment
#   with replicas=1 (NOT a DaemonSet like span-mirror-controller, which is
#   node-local by nature).
#
# Environment variables:
#   POLL_INTERVAL   — polling interval in seconds (default: 5)
#   OVN_NAMESPACE   — namespace of ovnkube-db pod (default: ovn-kubernetes)
#   DB_CONTAINER    — ovn-nbctl container (default: nb-ovsdb)
#   LOG_LEVEL       — DEBUG, INFO, WARN, ERROR (default: INFO)
#   ATTACKER_LABEL  — label selector for attacker pods (default: arp.kumi.io/attacker=true)

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================
POLL_INTERVAL="${POLL_INTERVAL:-5}"
OVN_NAMESPACE="${OVN_NAMESPACE:-ovn-kubernetes}"
DB_CONTAINER="${DB_CONTAINER:-nb-ovsdb}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
ATTACKER_LABEL="${ATTACKER_LABEL:-arp.kumi.io/attacker=true}"

# ============================================================================
# Logging
# ============================================================================
log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ "$LOG_LEVEL" == "DEBUG" ]] || [[ "$level" != "DEBUG" ]]; then
        echo "[$ts] [$level] $*"
    fi
}

# ============================================================================
# Kubernetes API helpers
# ============================================================================

get_attacker_pods() {
    kubectl get pods --all-namespaces \
        -l "$ATTACKER_LABEL" \
        --field-selector "status.phase=Running" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -v '^$' || true
}

# Find the ovnkube-db pod hosting the OVN NB database (label ovn-db-pod=true).
find_db_pod() {
    kubectl get pod -n "$OVN_NAMESPACE" -l ovn-db-pod=true \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# ============================================================================
# OVN NB helpers (via kubectl exec into nb-ovsdb container)
# ============================================================================

ovn_nbctl() {
    local db_pod="$1"; shift
    kubectl exec -n "$OVN_NAMESPACE" "$db_pod" -c "$DB_CONTAINER" -- \
        ovn-nbctl --timeout=10 "$@" 2>/dev/null || true
}

# List all logical switch port names (bare, one per line).
list_all_lsps() {
    local db_pod="$1"
    ovn_nbctl "$db_pod" --format=csv --data=bare --no-heading --columns=name \
        list logical_switch_port 2>/dev/null | grep -v '^$' || true
}

# Get current port_security value of an LSP (returns "[]" when empty).
get_port_security() {
    local db_pod="$1" lsp="$2"
    ovn_nbctl "$db_pod" get logical_switch_port "$lsp" port_security 2>/dev/null
}

clear_port_security() {
    local db_pod="$1" lsp="$2"
    ovn_nbctl "$db_pod" set logical_switch_port "$lsp" port_security=[] 2>/dev/null
}

# ============================================================================
# Core: reconcile port_security for all attacker pods
# ============================================================================

reconcile() {
    local db_pod
    db_pod=$(find_db_pod)
    if [[ -z "$db_pod" ]]; then
        log WARN "No ovnkube-db pod found (label ovn-db-pod=true) — skipping"
        return 0
    fi

    local attackers
    attackers=$(get_attacker_pods)
    if [[ -z "$attackers" ]]; then
        log DEBUG "No attacker pods ($ATTACKER_LABEL) — nothing to fix"
        return 0
    fi

    log DEBUG "Attacker pods: ${attackers//$'\n'/,}"

    # All LSP names, cluster-wide (single exec, then filter locally)
    local all_lsps
    all_lsps=$(list_all_lsps "$db_pod")
    if [[ -z "$all_lsps" ]]; then
        log WARN "No logical switch ports listed — skipping"
        return 0
    fi

    local changed=0
    while IFS= read -r attacker; do
        [[ -z "$attacker" ]] && continue
        local ns pod suffix
        ns=$(echo "$attacker" | cut -d'/' -f1)
        pod=$(echo "$attacker" | cut -d'/' -f2)
        # OVN-K LSP name suffix is "_<namespace>_<podname>" for primary and
        # secondary networks alike (e.g. user-superadmin_kali-attack-... and
        # user.superadmin...vlan10_user-superadmin_kali-attack-...).
        suffix="_${ns}_${pod}"

        # Resolve matching LSP names for this pod
        local pod_lsps
        pod_lsps=$(echo "$all_lsps" | grep -E "${suffix}$" || true)
        if [[ -z "$pod_lsps" ]]; then
            log WARN "No LSPs found for attacker $attacker (suffix ${suffix})"
            continue
        fi

        while IFS= read -r lsp; do
            [[ -z "$lsp" ]] && continue
            local ps
            ps=$(get_port_security "$db_pod" "$lsp")
            if [[ -n "$ps" && "$ps" != "[]" ]]; then
                log INFO "Clearing port_security on $lsp (was $ps)"
                if clear_port_security "$db_pod" "$lsp"; then
                    log INFO "  OK: $lsp → port_security=[]"
                    changed=1
                else
                    log ERROR "  FAILED to clear port_security on $lsp"
                fi
            else
                log DEBUG "port_security already empty on $lsp"
            fi
        done <<< "$pod_lsps"
    done <<< "$attackers"

    if [[ "$changed" -eq 0 ]]; then
        log DEBUG "No port_security changes required"
    fi
}

# ============================================================================
# Main loop
# ============================================================================

main() {
    log INFO "=========================================="
    log INFO "ARP Port-Security Fixer Controller starting"
    log INFO "OVN namespace:   $OVN_NAMESPACE"
    log INFO "DB container:    $DB_CONTAINER"
    log INFO "Poll interval:   ${POLL_INTERVAL}s"
    log INFO "Log level:       $LOG_LEVEL"
    log INFO "Attacker label:  $ATTACKER_LABEL"
    log INFO "=========================================="

    if ! kubectl get nodes >/dev/null 2>&1; then
        log ERROR "Cannot access Kubernetes API"
        exit 1
    fi

    log INFO "Initial reconcile..."
    reconcile

    log INFO "Entering main loop..."
    while true; do
        sleep "$POLL_INTERVAL"
        reconcile
    done
}

for cmd in kubectl; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

main "$@"
