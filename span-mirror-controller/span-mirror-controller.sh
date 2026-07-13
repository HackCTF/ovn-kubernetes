#!/bin/bash
# span-mirror-controller.sh — SPAN Mirror Controller (self-contained)
#
# Watches pods with labels:
#   mirror.kumi.io/target=true   → pods to mirror (sources)
#   mirror.kumi.io/sniffer=true  → destination pod (sink)
#
# Automatically reconfigures OVS SPAN mirror on br-int when ports change.
#
# Architecture designed for Go migration (Enfoque B):
#   - Shell polling → Go + libovsdb Monitor (real-time)
#   - kubectl query → K8s Informer
#   - State in memory → Struct with mutex
#   - OVS mirror ops → libovsdb Bridge/Mirror table transactions
#
# Limitation: only mirrors LOCAL ports (same node as sniffer).
# Labels:
#   mirror.kumi.io/target=true   → pod to mirror
#   mirror.kumi.io/sniffer=true  → mirror destination
#
# Environment variables:
#   NODE_NAME       — (required) set via Kubernetes Downward API
#   POLL_INTERVAL   — polling interval in seconds (default: 5)
#   MIRROR_NAME     — OVS mirror name (default: span-auto)
#   BRIDGE          — OVS bridge name (default: br-int)
#   OVS_NAMESPACE   — namespace of ovs-node pods (default: ovn-kubernetes)
#   LOG_LEVEL       — DEBUG, INFO, WARN, ERROR (default: INFO)

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MIRROR_NAME="${MIRROR_NAME:-span-auto}"
BRIDGE="${BRIDGE:-br-int}"
OVS_NAMESPACE="${OVS_NAMESPACE:-ovn-kubernetes}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
NODE_NAME="${NODE_NAME:-}"

# ============================================================================
# State tracking
# ============================================================================
PREV_STATE_SIG=""
CURRENT_TARGETS=""
CURRENT_SNIFFERS=""

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
#
# Go equivalent (Enfoque B):
#   K8s Informer with label selector + field selector
#   client-go: SharedInformerFactory + filtered lister
# ============================================================================

get_target_pods() {
    kubectl get pods --all-namespaces \
        -l "mirror.kumi.io/target=true" \
        --field-selector "spec.nodeName=$NODE_NAME,status.phase=Running" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -v '^$' || true
}

get_sniffer_pods() {
    kubectl get pods --all-namespaces \
        -l "mirror.kumi.io/sniffer=true" \
        --field-selector "spec.nodeName=$NODE_NAME,status.phase=Running" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -v '^$' || true
}

# ============================================================================
# OVS helpers (via kubectl exec into ovs-node container)
#
# Go equivalent (Enfoque B):
#   libovsdb client connected to unix:/var/run/openvswitch/db.sock
#   Direct table operations on Interface, Port, Bridge, Mirror
#   Monitor-based change detection (no polling)
# ============================================================================

find_ovs_pod() {
    kubectl get pod -n "$OVS_NAMESPACE" -l app=ovs-node \
        --field-selector "spec.nodeName=$NODE_NAME" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

ovs_exec() {
    local ovs_pod="$1"; shift
    kubectl exec -n "$OVS_NAMESPACE" "$ovs_pod" -c ovs-daemons -- \
        ovs-vsctl --timeout=10 "$@" 2>/dev/null || true
}

# List OVS interfaces with ofport and iface-id
# Output: ofport<TAB>iface-id per line
list_ovs_interfaces() {
    local ovs_pod="$1"
    ovs_exec "$ovs_pod" --columns=ofport,external_ids list Interface \
    | awk '
        /external_ids/ { in_ext=1; next }
        /ofport/ { if (match($0, /ofport\s*:\s*([0-9-]+)/, m)) ofport=m[1]; next }
        in_ext && /iface-id/ {
            gsub(/.*iface-id\s*:\s*"/, ""); gsub(/".*/, "")
            if (ofport != "" && ofport != "-1" && $0 != "") print ofport "\t" $0
            ofport=""; in_ext=0
        }
    '
}

clear_mirrors() {
    local ovs_pod="$1"
    log DEBUG "Clearing mirrors on $BRIDGE"
    ovs_exec "$ovs_pod" clear Bridge "$BRIDGE" mirrors || true
}

# Create mirror + clear + attach in SINGLE ovs-vsctl call.
#
# CRITICAL: All --id references (@p1, @d1, @sink, @m) must be in the SAME
# ovs-vsctl invocation — they do NOT persist across separate invocations.
# Use `--` to separate sub-commands within the same invocation.
#
# Args: ovs_pod src_ports_csv dst_ports_csv output_port
create_mirror() {
    local ovs_pod="$1"
    local src_ports_csv="$2"
    local dst_ports_csv="$3"
    local output_port="$4"

    if [[ -z "$src_ports_csv" || -z "$output_port" ]]; then
        log WARN "Cannot create mirror: src_ports or output_port empty"
        return 1
    fi

    # Build ovs-vsctl argument list (single invocation, all refs in same scope)
    local -a ovs_args=(--timeout=10)

    # Sub-command 1: clear existing mirrors on the bridge
    ovs_args+=(-- "clear" "Bridge" "$BRIDGE" "mirrors")

    # Sub-command 2: get @p refs for source ports
    local src_refs="" idx=1
    local IFS=','
    for port in $src_ports_csv; do
        port=$(echo "$port" | xargs)
        [[ -z "$port" ]] && continue
        src_refs="${src_refs:+$src_refs,}@p${idx}"
        ovs_args+=(-- "--id=@p${idx}" "get" "Port" "$port")
        idx=$((idx + 1))
    done

    # Sub-command 3: get @d refs for destination ports (same as source for SPAN)
    local dst_refs="" idx=1
    for port in $dst_ports_csv; do
        port=$(echo "$port" | xargs)
        [[ -z "$port" ]] && continue
        dst_refs="${dst_refs:+$dst_refs,}@d${idx}"
        ovs_args+=(-- "--id=@d${idx}" "get" "Port" "$port")
        idx=$((idx + 1))
    done

    # Sub-command 4: get @sink ref for output port
    ovs_args+=(-- "--id=@sink" "get" "Port" "$output_port")

    # Sub-command 5: create Mirror with all refs
    log INFO "Creating mirror: src=[$src_refs] output=@sink"
    ovs_args+=(
        -- "--id=@m" "create" "Mirror" "name=$MIRROR_NAME"
        "select_src_port=$src_refs"
        "select_dst_port=$dst_refs"
        "output_port=@sink"
    )

    # Sub-command 6: attach @m to bridge
    ovs_args+=(-- "add" "Bridge" "$BRIDGE" "mirrors" "@m")

    # Execute ALL in a single ovs-vsctl invocation
    local result
    result=$(kubectl exec -n "$OVS_NAMESPACE" "$ovs_pod" -c ovs-daemons -- \
        ovs-vsctl "${ovs_args[@]}" 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        log ERROR "Failed to create mirror (rc=$rc): $result"
        return 1
    fi

    log INFO "Mirror $MIRROR_NAME attached to $BRIDGE (uuid: $result)"
    return 0
}

# ============================================================================
# OVS port resolution
#
# Go equivalent (Enfoque B):
#   FindInterfacesWithPredicate() with ExternalIDs["iface-id"] filter
#   No awk parsing needed — libovsdb returns typed structs
# ============================================================================

find_sniffer_port() {
    local ovs_pod="$1" sniffer_ns="$2" sniffer_pod="$3"

    # OVN-K iface-id uses underscore separator: namespace_pod
    # Secondary iface-ids: <nad.name>_namespace_pod
    local pattern="${sniffer_ns}_${sniffer_pod}"
    local port_name
    port_name=$(kubectl exec -n "$OVS_NAMESPACE" "$ovs_pod" -c ovs-daemons -- \
        ovs-vsctl --timeout=10 --columns=name,external_ids list Interface \
    | awk -v pat="$pattern" '
        /^ *name *:/ {
            val = $0
            sub(/^ *name *: */, "", val)
            if (val ~ /^"/) { sub(/^"/, "", val); sub(/"$/, "", val) }
            sub(/[[:space:]]*$/, "", val)
            cur = val
        }
        /iface-id/ && index($0, pat) > 0 && cur != "" { print cur; exit }
    ' | head -1) || true

    [[ -n "$port_name" ]] && { echo "$port_name"; return 0; }

    log WARN "Could not find OVS port for sniffer $sniffer_ns/$sniffer_pod"
    return 1
}

find_target_ports() {
    local ovs_pod="$1" target_ns="$2" target_pod="$3"
    local iface_pattern="${target_ns}_${target_pod}"

    # OVS quotes names starting with digits (e.g. "76ac79b437a3a3a") but
    # not names starting with letters (e.g. aafdcf01710b830).
    # Use awk to handle both cases uniformly.
    kubectl exec -n "$OVS_NAMESPACE" "$ovs_pod" -c ovs-daemons -- \
        ovs-vsctl --timeout=10 --columns=name,external_ids list Interface \
    | awk -v pat="$iface_pattern" '
        /^ *name *:/ {
            # Extract value after "name :", strip optional quotes
            val = $0
            sub(/^ *name *: */, "", val)
            # Handle both quoted "value" and unquoted value
            if (val ~ /^"/) { sub(/^"/, "", val); sub(/"$/, "", val) }
            # Remove trailing whitespace
            sub(/[[:space:]]*$/, "", val)
            cur = val
        }
        /iface-id/ && index($0, pat) > 0 && cur != "" { print cur }
    ' || true
}

# ============================================================================
# State management
#
# Go equivalent (Enfoque B):
#   type State struct { Targets, Sniffers []string }
#   func (s *State) Equal(other *State) bool { return reflect.DeepEqual(s, other) }
# ============================================================================

generate_state_signature() {
    echo "t=$1|s=$2" | md5sum | cut -d' ' -f1
}

has_state_changed() {
    local new_sig
    new_sig=$(generate_state_signature "$CURRENT_TARGETS" "$CURRENT_SNIFFERS")
    if [[ "$new_sig" != "$PREV_STATE_SIG" ]]; then
        PREV_STATE_SIG="$new_sig"
        return 0
    fi
    return 1
}

# ============================================================================
# Core: reconfigure SPAN mirror
#
# Go equivalent (Enfoque B):
#   func (c *Controller) ReconfigureMirror(ctx context.Context) error {
#       targets := c.podLister.ListTargetPods()
#       sniffers := c.podLister.ListSnifferPods()
#       ports := c.ovsdb.ListInterfaces()
#       // ... map pods → OVS ports ...
#       return c.ovsdb.UpdateMirror(ctx, mirror)
#   }
# ============================================================================

reconfigure_mirror() {
    local ovs_pod
    ovs_pod=$(find_ovs_pod)

    if [[ -z "$ovs_pod" ]]; then
        log WARN "No ovs-node pod found on $NODE_NAME — skipping"
        return 0
    fi

    if [[ -z "$CURRENT_TARGETS" ]]; then
        log INFO "No target pods — clearing mirror"
        clear_mirrors "$ovs_pod"
        return 0
    fi

    if [[ -z "$CURRENT_SNIFFERS" ]]; then
        log INFO "No sniffer pods — clearing mirror"
        clear_mirrors "$ovs_pod"
        return 0
    fi

    # Use first sniffer
    local sniffer_ns sniffer_pod
    sniffer_ns=$(echo "$CURRENT_SNIFFERS" | head -1 | cut -d'/' -f1)
    sniffer_pod=$(echo "$CURRENT_SNIFFERS" | head -1 | cut -d'/' -f2)
    log INFO "Sniffer: $sniffer_ns/$sniffer_pod"

    local sniffer_port
    sniffer_port=$(find_sniffer_port "$ovs_pod" "$sniffer_ns" "$sniffer_pod")
    if [[ -z "$sniffer_port" ]]; then
        log WARN "Sniffer port not found — clearing mirror"
        clear_mirrors "$ovs_pod"
        return 0
    fi
    log INFO "Sniffer OVS port: $sniffer_port"

    # Resolve all target OVS ports
    local all_target_ports=""
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        local t_ns t_pod ports
        t_ns=$(echo "$target" | cut -d'/' -f1)
        t_pod=$(echo "$target" | cut -d'/' -f2)
        ports=$(find_target_ports "$ovs_pod" "$t_ns" "$t_pod")
        if [[ -n "$ports" ]]; then
            log INFO "Target $t_ns/$t_pod → OVS ports: $(echo $ports | tr '\n' ' ')"
            all_target_ports="${all_target_ports:+$all_target_ports
}$ports"
        else
            log WARN "Target $t_ns/$t_pod — no OVS ports found"
        fi
    done <<< "$CURRENT_TARGETS"

    all_target_ports=$(echo "$all_target_ports" | sort -u | grep -v '^$')
    if [[ -z "$all_target_ports" ]]; then
        log WARN "No target OVS ports resolved — clearing mirror"
        clear_mirrors "$ovs_pod"
        return 0
    fi

    local port_csv
    port_csv=$(echo "$all_target_ports" | tr '\n' ',' | sed 's/,$//')

    log INFO "Configuring mirror: targets=[$port_csv] → sniffer=$sniffer_port"
    # create_mirror handles clear + create + attach in a SINGLE ovs-vsctl call
    create_mirror "$ovs_pod" "$port_csv" "$port_csv" "$sniffer_port" \
        && log INFO "SPAN mirror reconfigured successfully" \
        || log ERROR "Failed to reconfigure mirror"
}

# ============================================================================
# Main loop
# ============================================================================

main() {
    log INFO "=========================================="
    log INFO "SPAN Mirror Controller starting"
    log INFO "Node:            $NODE_NAME"
    log INFO "Bridge:          $BRIDGE"
    log INFO "Mirror name:     $MIRROR_NAME"
    log INFO "Poll interval:   ${POLL_INTERVAL}s"
    log INFO "Log level:       $LOG_LEVEL"
    log INFO "Target label:    mirror.kumi.io/target=true"
    log INFO "Sniffer label:   mirror.kumi.io/sniffer=true"
    log INFO "Migration note:  Enfoque B (Go+libovsdb) recommended for production"
    log INFO "=========================================="

    if ! kubectl get nodes >/dev/null 2>&1; then
        log ERROR "Cannot access Kubernetes API"
        exit 1
    fi

    log INFO "Initial pod discovery..."
    discover_pods

    if [[ -n "$CURRENT_TARGETS" || -n "$CURRENT_SNIFFERS" ]]; then
        log INFO "Found targets=[${CURRENT_TARGETS//$'\n'/,}] sniffers=[${CURRENT_SNIFFERS//$'\n'/,}]"
        reconfigure_mirror
    else
        log INFO "No target or sniffer pods found — waiting..."
    fi

    log INFO "Entering main loop..."
    while true; do
        sleep "$POLL_INTERVAL"
        discover_pods
        if has_state_changed; then
            log INFO "State change detected — reconfiguring mirror"
            reconfigure_mirror
        else
            log DEBUG "No state change"
        fi
    done
}

# ============================================================================
# Entry point
# ============================================================================

discover_pods() {
    CURRENT_TARGETS=$(get_target_pods)
    CURRENT_SNIFFERS=$(get_sniffer_pods)
    log DEBUG "Targets: ${CURRENT_TARGETS:-none}"
    log DEBUG "Sniffers: ${CURRENT_SNIFFERS:-none}"
}

for cmd in kubectl; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

[[ -z "$NODE_NAME" ]] && { echo "ERROR: NODE_NAME not set"; exit 1; }

main "$@"
